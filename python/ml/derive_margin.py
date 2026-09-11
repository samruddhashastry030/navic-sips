"""
Find a logit-margin rule the firmware can use instead of a softmax threshold.

The model's tuned decision rule is "predict SEVERE if P(SEVERE) >= t", which
needs three exponentials per inference. PicoRV32 has no FPU, so that is slow
and awkward. A margin rule -- "predict SEVERE if logit_severe exceeds the
runner-up by at least m" -- needs only comparisons and a subtraction.

The two are NOT equivalent. This script measures how close they get:

  1. sweeps m on the VALIDATION split to best reproduce the tuned rule
  2. reports how often the two rules disagree
  3. scores both on the TEST split, so the cost of the approximation is a
     measured number rather than an assumption

If the margin rule lands within a few thousandths of the tuned rule, the
firmware uses it. If not, the honest answer is plain argmax and its known
cost, which the script also prints.

Usage:
    python3 python/ml/derive_margin.py \
        --model sim/lstm_l1only/lstm_h8_l2.pt \
        --data sim/vectors_cosmic2_l1only/cosmic2_dataset.npz
"""
import argparse
import json
import os

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import TensorDataset, DataLoader

SEVERE = 2
S4_FRAC = 8          # Q8.8, matching the logits the accelerator emits


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
    def __init__(self, n_features=2, hidden=8, layers=2, n_classes=3):
        super().__init__()
        self.lstm = nn.LSTM(input_size=n_features, hidden_size=hidden,
                            num_layers=layers, batch_first=True)
        self.head = nn.Linear(hidden, n_classes)

    def forward(self, x):
        out, _ = self.lstm(x)
        return self.head(out[:, -1, :])


def severe_f1(y_true, y_pred):
    tp = int(np.sum((y_pred == SEVERE) & (y_true == SEVERE)))
    fp = int(np.sum((y_pred == SEVERE) & (y_true != SEVERE)))
    fn = int(np.sum((y_pred != SEVERE) & (y_true == SEVERE)))
    p = tp / (tp + fp) if (tp + fp) else 0.0
    r = tp / (tp + fn) if (tp + fn) else 0.0
    return (2 * p * r / (p + r) if (p + r) else 0.0), p, r


def by_threshold(prob, t):
    pred = np.argmax(prob[:, :2], axis=1)
    pred[prob[:, 2] >= t] = SEVERE
    return pred


def by_margin(logits, m):
    """SEVERE if logit_severe beats BOTH others by at least m."""
    l0, l1, l2 = logits[:, 0], logits[:, 1], logits[:, 2]
    runner_up = np.maximum(l0, l1)
    pred = np.where(l0 >= l1, 0, 1)
    pred[(l2 - runner_up) >= m] = SEVERE
    return pred


@torch.no_grad()
def run(model, x, batch=8192):
    model.eval()
    dl = DataLoader(TensorDataset(torch.from_numpy(x).float()),
                    batch_size=batch, shuffle=False)
    out = []
    for (xb,) in dl:
        out.append(model(xb).numpy())
    return np.concatenate(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    ck = torch.load(args.model, map_location="cpu", weights_only=False)
    hidden, layers = ck["hidden"], ck["layers"]
    thr = ck.get("threshold", 0.5)
    mu = np.array(ck["norm"]["mu"], dtype=np.float32)
    sd = np.array(ck["norm"]["sd"], dtype=np.float32)

    d = np.load(args.data)
    x, y = d["X"], d["y"]
    ev = d["event_ids"] if "event_ids" in d else np.arange(len(y))
    _, va, te = event_split(ev, seed=args.seed)

    model = ScintLSTM(x.shape[2], hidden, layers)
    model.load_state_dict(ck["state_dict"])

    print("model: %s  hidden=%d layers=%d  stored threshold %.2f"
          % (os.path.basename(args.model), hidden, layers, thr))

    lg_va = run(model, (x[va] - mu) / sd)
    lg_te = run(model, (x[te] - mu) / sd)
    pr_va = torch.softmax(torch.from_numpy(lg_va), dim=1).numpy()
    pr_te = torch.softmax(torch.from_numpy(lg_te), dim=1).numpy()

    ref_va = by_threshold(pr_va, thr)

    # ---- sweep the margin on validation ---------------------------------
    print("\nsweeping margin on the validation split (%d samples)" % va.sum())
    best_m, best_agree = 0.0, -1.0
    rows = []
    for m in np.arange(-2.0, 4.01, 0.05):
        pred = by_margin(lg_va, m)
        agree = float(np.mean(pred == ref_va))
        f1, _, _ = severe_f1(y[va], pred)
        rows.append((float(m), agree, f1))
        if agree > best_agree:
            best_agree, best_m = agree, float(m)

    f1_ref_va, _, _ = severe_f1(y[va], ref_va)
    print("  best margin %.2f  agrees with the tuned rule on %.3f%% of samples"
          % (best_m, 100 * best_agree))
    print("  val SEVERE F1: tuned %.4f   margin %.4f"
          % (f1_ref_va, severe_f1(y[va], by_margin(lg_va, best_m))[0]))

    # ---- score everything on test ---------------------------------------
    print("\nTEST split (%d samples, %d SEVERE)"
          % (te.sum(), int(np.sum(y[te] == SEVERE))))
    print("  %-22s %8s %8s %8s" % ("rule", "prec", "rec", "F1"))

    results = {}
    for name, pred in (
        ("plain argmax", np.argmax(lg_te, axis=1)),
        ("softmax threshold %.2f" % thr, by_threshold(pr_te, thr)),
        ("logit margin %.2f" % best_m, by_margin(lg_te, best_m)),
    ):
        f1, p, r = severe_f1(y[te], pred)
        print("  %-22s %8.4f %8.4f %8.4f" % (name, p, r, f1))
        results[name] = dict(precision=p, recall=r, f1=f1)

    tuned = results["softmax threshold %.2f" % thr]["f1"]
    marg = results["logit margin %.2f" % best_m]["f1"]
    argm = results["plain argmax"]["f1"]
    print("\n  margin rule costs %+.4f against the softmax threshold"
          % (marg - tuned))
    print("  plain argmax costs %+.4f against the softmax threshold"
          % (argm - tuned))

    if abs(marg - tuned) < 0.005:
        print("\n  VERDICT: the margin rule reproduces the tuned threshold.")
        print("  Firmware compares (logit_severe - max(other two)) >= %d"
              % int(round(best_m * (1 << S4_FRAC))))
        print("  which in Q8.8 is 0x%04X." % (int(round(best_m * (1 << S4_FRAC))) & 0xFFFF))
    else:
        print("\n  VERDICT: the margin rule does NOT reproduce the threshold.")
        print("  Use plain argmax and accept %+.4f, or compute softmax."
              % (argm - tuned))

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "margin_results.json"), "w") as f:
            json.dump(dict(model=args.model, threshold=thr,
                           best_margin=best_m,
                           best_margin_q88=int(round(best_m * (1 << S4_FRAC))),
                           val_agreement=best_agree, test=results),
                      f, indent=2)
        print("\nwritten to %s" % args.out)


if __name__ == "__main__":
    main()
