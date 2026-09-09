"""
Train the scintillation-forecasting LSTM on a dataset built by
cosmic2_dataset.py (or phase_screen.py --dataset).

Mirrors python/ml/baseline.py conventions:
  - splits by EVENT, never by sample, so overlapping windows cannot leak
  - reports SEVERE precision / recall / F1, never accuracy
  - the number to beat is the gradient-boosting SEVERE F1 from baseline.py

Key additions over the first version:
  - a decision threshold on P(SEVERE) tuned on the VALIDATION split and then
    applied unchanged to test. Class-weighted training parks the model at a
    recall-heavy operating point; F1 peaks near balanced precision/recall,
    so the raw argmax understates what the model can do.
  - --weight-mode sqrt (default) softens inverse-frequency weighting, which
    at full strength puts ~44x on SEVERE and over-predicts badly.
  - ReduceLROnPlateau, since a fixed 2e-3 made validation F1 bounce.

Usage:
    python3 python/ml/lstm_train.py --data <npz> --bar 0.523
    python3 python/ml/lstm_train.py --data <npz> --bar 0.523 --sweep
    python3 python/ml/lstm_train.py --data <npz> --weight-mode inverse
"""
import argparse
import json
import os
import time

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import TensorDataset, DataLoader

CLASS_NAMES = ["NOMINAL", "DEGRADED", "SEVERE"]
SEVERE = 2


def event_split(event_ids, test_frac=0.2, val_frac=0.2, seed=0):
    uniq = np.unique(event_ids)
    rng = np.random.default_rng(seed)
    rng.shuffle(uniq)
    n = len(uniq)
    n_test = int(round(n * test_frac))
    n_val = int(round(n * val_frac))
    test_ev = set(uniq[:n_test].tolist())
    val_ev = set(uniq[n_test:n_test + n_val].tolist())
    is_test = np.array([e in test_ev for e in event_ids])
    is_val = np.array([e in val_ev for e in event_ids])
    return ~(is_test | is_val), is_val, is_test


def undersample_nominal(y, mask, max_ratio, seed=0):
    if max_ratio is None or max_ratio <= 0:
        return mask
    idx = np.flatnonzero(mask)
    y_sub = y[idx]
    nominal = idx[y_sub == 0]
    other = idx[y_sub != 0]
    keep_n = int(len(other) * max_ratio)
    if keep_n >= len(nominal):
        return mask
    rng = np.random.default_rng(seed)
    kept = rng.choice(nominal, size=keep_n, replace=False)
    new_mask = np.zeros_like(mask)
    new_mask[np.concatenate([kept, other])] = True
    return new_mask


class ScintLSTM(nn.Module):
    def __init__(self, n_features=2, hidden=16, layers=2, n_classes=3, dropout=0.0):
        super().__init__()
        self.lstm = nn.LSTM(input_size=n_features, hidden_size=hidden,
                            num_layers=layers, batch_first=True,
                            dropout=dropout if layers > 1 else 0.0)
        self.head = nn.Linear(hidden, n_classes)

    def forward(self, x):
        out, _ = self.lstm(x)
        return self.head(out[:, -1, :])

    def n_params(self):
        return sum(p.numel() for p in self.parameters())


def metrics(y_true, y_pred):
    out = {}
    for c in range(3):
        tp = int(np.sum((y_pred == c) & (y_true == c)))
        fp = int(np.sum((y_pred == c) & (y_true != c)))
        fn = int(np.sum((y_pred != c) & (y_true == c)))
        prec = tp / (tp + fp) if (tp + fp) else 0.0
        rec = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
        out[c] = dict(precision=prec, recall=rec, f1=f1,
                      support=int(np.sum(y_true == c)))
    out["accuracy"] = float(np.mean(y_pred == y_true))
    out["macro_f1"] = float(np.mean([out[c]["f1"] for c in range(3)]))
    return out


def fbeta(prec, rec, beta):
    b2 = beta * beta
    d = b2 * prec + rec
    return (1 + b2) * prec * rec / d if d else 0.0


def report(m, label=""):
    print("  %s" % label)
    print("  accuracy: %.3f   <-- ignore this, see SEVERE recall" % m["accuracy"])
    print("  class      prec    rec     F1     n")
    for c in range(3):
        d = m[c]
        print("  %-9s %.3f  %.3f  %.3f  %7d"
              % (CLASS_NAMES[c], d["precision"], d["recall"], d["f1"], d["support"]))


def confusion(y_true, y_pred):
    print("  confusion (rows=true, cols=pred):")
    for c in range(3):
        row = [int(np.sum((y_true == c) & (y_pred == p))) for p in range(3)]
        print("    %-9s %7d %7d %7d" % (CLASS_NAMES[c], row[0], row[1], row[2]))


@torch.no_grad()
def probabilities(model, loader, device):
    model.eval()
    probs, trues = [], []
    for xb, yb in loader:
        p = torch.softmax(model(xb.to(device)), dim=1)
        probs.append(p.cpu().numpy())
        trues.append(yb.numpy())
    return np.concatenate(trues), np.concatenate(probs)


def apply_threshold(prob, thr):
    """SEVERE if P(SEVERE) >= thr, else argmax over the remaining classes."""
    pred = np.argmax(prob[:, :2], axis=1)
    pred[prob[:, 2] >= thr] = 2
    return pred


def tune_threshold(y_true, prob, beta=1.0):
    """Pick the P(SEVERE) threshold maximising F-beta on this split."""
    best_t, best_s = 0.5, -1.0
    for t in np.arange(0.05, 0.96, 0.01):
        m = metrics(y_true, apply_threshold(prob, t))
        s = fbeta(m[SEVERE]["precision"], m[SEVERE]["recall"], beta)
        if s > best_s:
            best_s, best_t = s, float(t)
    return best_t, best_s


def class_weights(counts, mode):
    counts = np.maximum(counts, 1).astype(float)
    if mode == "none":
        return np.ones(3)
    inv = counts.sum() / (3.0 * counts)
    if mode == "inverse":
        return inv
    if mode == "sqrt":
        return np.sqrt(inv)
    raise ValueError(mode)


def train_one(x, y, ev, hidden, layers, args, device):
    tr, va, te = event_split(ev, seed=args.seed)
    tr = undersample_nominal(y, tr, args.max_nominal_ratio, seed=args.seed)

    print("split: %d train / %d val / %d test samples"
          % (tr.sum(), va.sum(), te.sum()))
    print("       %d / %d / %d distinct events"
          % (len(np.unique(ev[tr])), len(np.unique(ev[va])), len(np.unique(ev[te]))))
    counts_tr = np.bincount(y[tr], minlength=3)
    print("train class counts: NOMINAL=%d DEGRADED=%d SEVERE=%d" % tuple(counts_tr))

    mu = x[tr].reshape(-1, x.shape[2]).mean(0)
    sd = x[tr].reshape(-1, x.shape[2]).std(0)
    sd[sd == 0] = 1.0

    def to_ds(mask, shuffle):
        xt = torch.from_numpy((x[mask] - mu) / sd).float()
        yt = torch.from_numpy(y[mask]).long()
        return DataLoader(TensorDataset(xt, yt), batch_size=args.batch,
                          shuffle=shuffle, num_workers=0)

    dl_tr, dl_va, dl_te = to_ds(tr, True), to_ds(va, False), to_ds(te, False)

    model = ScintLSTM(x.shape[2], hidden, layers, dropout=args.dropout).to(device)
    print("model: hidden=%d layers=%d params=%d" % (hidden, layers, model.n_params()))

    w = class_weights(counts_tr, args.weight_mode)
    print("class weights (%s): %s" % (args.weight_mode, np.round(w, 3).tolist()))
    crit = nn.CrossEntropyLoss(
        weight=torch.tensor(w, dtype=torch.float32, device=device))
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.ReduceLROnPlateau(
        opt, mode="max", factor=0.5, patience=2)

    best_score, best_state, best_thr, bad = -1.0, None, 0.5, 0
    for ep in range(1, args.epochs + 1):
        model.train()
        t0, total = time.time(), 0.0
        for xb, yb in dl_tr:
            xb, yb = xb.to(device), yb.to(device)
            opt.zero_grad()
            loss = crit(model(xb), yb)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 5.0)
            opt.step()
            total += loss.item() * len(yb)

        yt, pv = probabilities(model, dl_va, device)
        thr, tuned = tune_threshold(yt, pv, beta=args.beta)
        raw = metrics(yt, np.argmax(pv, axis=1))[SEVERE]["f1"]
        sched.step(tuned)
        print("  epoch %2d  loss %.4f  val SEVERE F1 raw %.3f / tuned %.3f "
              "(thr %.2f)  lr %.1e  (%.0fs)"
              % (ep, total / max(tr.sum(), 1), raw, tuned, thr,
                 opt.param_groups[0]["lr"], time.time() - t0))

        if tuned > best_score:
            best_score, best_thr = tuned, thr
            best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
            bad = 0
        else:
            bad += 1
            if bad >= args.patience:
                print("  early stop (no val improvement for %d epochs)" % args.patience)
                break

    if best_state is not None:
        model.load_state_dict(best_state)

    yt, pt = probabilities(model, dl_te, device)

    m_raw = metrics(yt, np.argmax(pt, axis=1))
    print("\n  --- TEST, raw argmax ---")
    report(m_raw, "hidden=%d layers=%d" % (hidden, layers))

    pred = apply_threshold(pt, best_thr)
    m_tun = metrics(yt, pred)
    print("\n  --- TEST, threshold %.2f tuned on validation ---" % best_thr)
    report(m_tun, "hidden=%d layers=%d" % (hidden, layers))
    confusion(yt, pred)
    d = m_tun[SEVERE]
    print("  SEVERE F2 (recall-weighted): %.3f"
          % fbeta(d["precision"], d["recall"], 2.0))
    print()

    return model, m_raw, m_tun, best_thr, dict(mu=mu.tolist(), sd=sd.tolist())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default="sim/lstm/")
    ap.add_argument("--hidden", type=int, default=16)
    ap.add_argument("--layers", type=int, default=2)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=1024)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--dropout", type=float, default=0.0)
    ap.add_argument("--patience", type=int, default=5)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--beta", type=float, default=1.0,
                    help="F-beta used for threshold tuning; >1 favours recall")
    ap.add_argument("--weight-mode", choices=["sqrt", "inverse", "none"],
                    default="sqrt")
    ap.add_argument("--max-nominal-ratio", type=float, default=0.0,
                    help="cap NOMINAL in TRAIN at this multiple of the other "
                         "classes; 0 disables thinning (default, since class "
                         "weights already correct the imbalance)")
    ap.add_argument("--sweep", action="store_true")
    ap.add_argument("--bar", type=float, default=None)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    device = torch.device("cpu")

    d = np.load(args.data)
    x, y = d["X"], d["y"]
    ev = d["event_ids"] if "event_ids" in d else np.arange(len(y))
    counts = np.bincount(y, minlength=3)
    print("loaded %s: %s" % (args.data, str(x.shape)))
    print("class balance: NOMINAL=%d DEGRADED=%d SEVERE=%d (SEVERE = %.1f%%)"
          % (counts[0], counts[1], counts[2], 100.0 * counts[2] / len(y)))
    print()

    os.makedirs(args.out, exist_ok=True)
    configs = ([(8, 1), (8, 2), (16, 1), (16, 2), (32, 1), (32, 2)]
               if args.sweep else [(args.hidden, args.layers)])

    results = {}
    for hidden, layers in configs:
        print("=" * 62)
        print("CONFIG hidden=%d layers=%d" % (hidden, layers))
        print("=" * 62)
        model, m_raw, m_tun, thr, norm = train_one(
            x, y, ev, hidden, layers, args, device)
        key = "h%d_l%d" % (hidden, layers)
        results[key] = dict(
            hidden=hidden, layers=layers, params=model.n_params(),
            threshold=thr,
            severe_f1_raw=m_raw[SEVERE]["f1"],
            severe_precision=m_tun[SEVERE]["precision"],
            severe_recall=m_tun[SEVERE]["recall"],
            severe_f1=m_tun[SEVERE]["f1"],
            severe_f2=fbeta(m_tun[SEVERE]["precision"],
                            m_tun[SEVERE]["recall"], 2.0),
            macro_f1=m_tun["macro_f1"], accuracy=m_tun["accuracy"])
        torch.save(dict(state_dict=model.state_dict(), hidden=hidden,
                        layers=layers, norm=norm, threshold=thr),
                   os.path.join(args.out, "lstm_%s.pt" % key))

    print("=" * 62)
    print("SUMMARY (threshold tuned on validation)")
    print("=" * 62)
    print("  config      params   thr   SEV prec  SEV rec  SEV F1  (raw F1)")
    for k, r in results.items():
        print("  %-10s %6d  %.2f  %8.3f %8.3f %7.3f  %7.3f"
              % (k, r["params"], r["threshold"], r["severe_precision"],
                 r["severe_recall"], r["severe_f1"], r["severe_f1_raw"]))
    best = max(results.items(), key=lambda kv: kv[1]["severe_f1"])
    print("\n  best: %s, SEVERE F1 = %.3f" % (best[0], best[1]["severe_f1"]))
    if args.bar is not None:
        delta = best[1]["severe_f1"] - args.bar
        print("  baseline bar = %.3f -> %s it by %+.3f"
              % (args.bar, "BEATS" if delta > 0 else "does NOT beat", delta))
    print("=" * 62)

    with open(os.path.join(args.out, "lstm_results.json"), "w") as f:
        json.dump(dict(data=args.data, seed=args.seed,
                       weight_mode=args.weight_mode, beta=args.beta,
                       max_nominal_ratio=args.max_nominal_ratio,
                       bar=args.bar, results=results), f, indent=2)
    print("written to %s" % args.out)


if __name__ == "__main__":
    main()
