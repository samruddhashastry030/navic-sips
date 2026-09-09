"""
Score a trained ScintLSTM against any dataset, without retraining.

Answers the questions lstm_train.py cannot, because it always trains:
  - does the globally trained model transfer to the Indian sector?
  - does an equinox-trained model over-predict in the quiet solstice season?
  - does a 2024 model still work on 2026 data as solar activity declines?

By default the whole dataset is used, since none of it was seen in training
when the target is a holdout set. Pass --split test to score only the test
portion instead, which is the right choice when evaluating a model on the
same dataset it was trained from.

Usage:
    # out-of-season holdout, all of it unseen
    python3 python/ml/evaluate.py \
        --model sim/lstm_global3/lstm_h16_l2.pt \
        --data sim/vectors_holdout_global/cosmic2_dataset.npz \
        --bar 0.523

    # regional transfer
    python3 python/ml/evaluate.py \
        --model sim/lstm_global3/lstm_h16_l2.pt \
        --data sim/vectors_cosmic2_india/cosmic2_dataset.npz \
        --bar 0.392

    # re-tune the threshold on this dataset instead of reusing the stored one
    python3 python/ml/evaluate.py --model <pt> --data <npz> --retune
"""
import argparse
import json
import os

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


class ScintLSTM(nn.Module):
    def __init__(self, n_features=2, hidden=16, layers=2, n_classes=3):
        super().__init__()
        self.lstm = nn.LSTM(input_size=n_features, hidden_size=hidden,
                            num_layers=layers, batch_first=True)
        self.head = nn.Linear(hidden, n_classes)

    def forward(self, x):
        out, _ = self.lstm(x)
        return self.head(out[:, -1, :])


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


def apply_threshold(prob, thr):
    pred = np.argmax(prob[:, :2], axis=1)
    pred[prob[:, 2] >= thr] = 2
    return pred


def report(m, label):
    print("  %s" % label)
    print("  accuracy: %.3f   <-- ignore this, see SEVERE recall" % m["accuracy"])
    print("  class      prec    rec     F1       n")
    for c in range(3):
        d = m[c]
        print("  %-9s %.3f  %.3f  %.3f  %8d"
              % (CLASS_NAMES[c], d["precision"], d["recall"], d["f1"], d["support"]))


def confusion(y_true, y_pred):
    print("  confusion (rows=true, cols=pred):")
    for c in range(3):
        row = [int(np.sum((y_true == c) & (y_pred == p))) for p in range(3)]
        print("    %-9s %8d %8d %8d" % (CLASS_NAMES[c], row[0], row[1], row[2]))


@torch.no_grad()
def probabilities(model, x, batch=8192):
    model.eval()
    ds = DataLoader(TensorDataset(torch.from_numpy(x).float()),
                    batch_size=batch, shuffle=False)
    out = []
    for (xb,) in ds:
        out.append(torch.softmax(model(xb), dim=1).numpy())
    return np.concatenate(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--bar", type=float, default=None)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--split", choices=["all", "test"], default="all",
                    help="'all' for a genuinely unseen dataset; 'test' when "
                         "the model was trained on this same dataset")
    ap.add_argument("--retune", action="store_true",
                    help="re-pick the threshold on this dataset (optimistic, "
                         "reports what the ceiling would be after tuning)")
    args = ap.parse_args()

    ck = torch.load(args.model, map_location="cpu", weights_only=False)
    hidden, layers = ck["hidden"], ck["layers"]
    thr = ck.get("threshold", 0.5)
    mu = np.array(ck["norm"]["mu"], dtype=np.float32)
    sd = np.array(ck["norm"]["sd"], dtype=np.float32)

    d = np.load(args.data)
    x, y = d["X"], d["y"]
    ev = d["event_ids"] if "event_ids" in d else np.arange(len(y))
    if args.split == "test":
        _, _, mask = event_split(ev, seed=args.seed)
        x, y = x[mask], y[mask]

    model = ScintLSTM(x.shape[2], hidden, layers)
    model.load_state_dict(ck["state_dict"])

    counts = np.bincount(y, minlength=3)
    print("model: %s (hidden=%d layers=%d, stored threshold %.2f)"
          % (os.path.basename(args.model), hidden, layers, thr))
    print("data:  %s  split=%s" % (args.data, args.split))
    print("       %d samples  NOMINAL=%d DEGRADED=%d SEVERE=%d (SEVERE = %.2f%%)"
          % (len(y), counts[0], counts[1], counts[2],
             100.0 * counts[2] / len(y)))
    print()

    prob = probabilities(model, (x - mu) / sd)

    m_raw = metrics(y, np.argmax(prob, axis=1))
    print("=" * 66)
    print("RAW ARGMAX")
    print("=" * 66)
    report(m_raw, "")
    print()

    print("=" * 66)
    print("STORED THRESHOLD %.2f (chosen on the training dataset)" % thr)
    print("=" * 66)
    pred = apply_threshold(prob, thr)
    m_thr = metrics(y, pred)
    report(m_thr, "")
    confusion(y, pred)
    dd = m_thr[SEVERE]
    print("  SEVERE F2 (recall-weighted): %.3f"
          % fbeta(dd["precision"], dd["recall"], 2.0))
    print()

    result = dict(model=args.model, data=args.data, split=args.split,
                  samples=int(len(y)), stored_threshold=thr,
                  raw_severe_f1=m_raw[SEVERE]["f1"],
                  severe_precision=m_thr[SEVERE]["precision"],
                  severe_recall=m_thr[SEVERE]["recall"],
                  severe_f1=m_thr[SEVERE]["f1"],
                  severe_f2=fbeta(dd["precision"], dd["recall"], 2.0),
                  accuracy=m_thr["accuracy"])

    if args.retune:
        best_t, best_f1 = thr, -1.0
        for t in np.arange(0.05, 0.96, 0.01):
            mm = metrics(y, apply_threshold(prob, t))
            if mm[SEVERE]["f1"] > best_f1:
                best_f1, best_t = mm[SEVERE]["f1"], float(t)
        print("=" * 66)
        print("RE-TUNED ON THIS DATASET (optimistic ceiling, not a fair score)")
        print("=" * 66)
        mm = metrics(y, apply_threshold(prob, best_t))
        report(mm, "threshold %.2f" % best_t)
        print()
        result["retuned_threshold"] = best_t
        result["retuned_severe_f1"] = mm[SEVERE]["f1"]

    print("=" * 66)
    print("SUMMARY")
    print("=" * 66)
    print("  raw argmax SEVERE F1      : %.3f" % result["raw_severe_f1"])
    print("  stored threshold SEVERE F1: %.3f" % result["severe_f1"])
    if args.retune:
        print("  re-tuned SEVERE F1        : %.3f (thr %.2f)"
              % (result["retuned_severe_f1"], result["retuned_threshold"]))
    if args.bar is not None:
        best = max(result["severe_f1"], result["raw_severe_f1"])
        delta = best - args.bar
        print("  bar = %.3f -> %s it by %+.3f"
              % (args.bar, "BEATS" if delta > 0 else "does NOT beat", delta))
    fa = int(np.sum((y == 0) & (pred == 2)))
    print("  false alarms (true NOMINAL called SEVERE): %d of %d (%.4f%%)"
          % (fa, counts[0], 100.0 * fa / max(counts[0], 1)))
    print("=" * 66)

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "eval_results.json"), "w") as f:
            json.dump(result, f, indent=2)
        print("written to %s" % args.out)


if __name__ == "__main__":
    main()
