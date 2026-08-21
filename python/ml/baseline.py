#!/usr/bin/env python3
"""
NavIC-SIPS — baseline models and evaluation protocol.

WHY THIS EXISTS
---------------
Published ML work on scintillation severity classification reports gradient
boosting reaching roughly 77% accuracy on a balanced three-class task. If our
LSTM accelerator does not beat a model that runs in microseconds on a CPU,
the chip has no result — however clean the GDSII is.

So: build the bar first, in September, not February.

This file defines three things:

  1. THE BASELINES the LSTM must beat
       - majority-class (the "predict NOMINAL forever" trap)
       - climatology only (local time, day of year, F10.7, Kp)
       - climatology + current indices
       - gradient boosting on the same features

  2. THE EVALUATION PROTOCOL
       - EVENT-WISE splitting, never random
       - precision / recall / F1 on the SEVERE class, never accuracy
       - class weighting to handle the imbalance

  3. THE HARNESS the LSTM plugs into later, so the comparison is like-for-like.

THE TWO TRAPS THIS FILE EXISTS TO AVOID
---------------------------------------
1. ACCURACY. Scintillation is rare. A model predicting NOMINAL forever scores
   ~96% "accuracy" and is worthless. The majority baseline below makes that
   visible immediately.

2. RANDOM SPLITTING. Adjacent samples in a time series are near-identical.
   Random train/test splits leak test data into training and produce a
   beautiful, meaningless validation curve. Hold out whole events.

USAGE
    # generate data first
    python3 python/golden/phase_screen.py --dataset --n-events 600 --out sim/vectors/

    python3 python/ml/baseline.py --data sim/vectors/scint_dataset.npz
    python3 python/ml/baseline.py --demo          # self-contained
"""

import argparse
import json
import os

import numpy as np

CLASS_NAMES = ["NOMINAL", "DEGRADED", "SEVERE"]
SEVERE = 2


# --------------------------------------------------------------------------
# Climatology features
# --------------------------------------------------------------------------
def climatology_features(local_hour, day_of_year, f107, kp):
    """
    Physically motivated features for scintillation OCCURRENCE.

    Equatorial plasma bubbles are strongly diurnal (post-sunset) with
    equinoctial maxima. Encoding those cyclically rather than as raw numbers
    lets a linear model use them.

    TRACK A should confirm the post-sunset window and equinox months for the
    Indian sector against a primary source before these are used in the paper.
    """
    lh = np.asarray(local_hour, float)
    doy = np.asarray(day_of_year, float)
    f = np.asarray(f107, float)
    k = np.asarray(kp, float)

    # cyclic encodings — 23:00 and 01:00 must be close together
    hour_sin = np.sin(2 * np.pi * lh / 24.0)
    hour_cos = np.cos(2 * np.pi * lh / 24.0)
    doy_sin = np.sin(2 * np.pi * doy / 365.25)
    doy_cos = np.cos(2 * np.pi * doy / 365.25)

    # explicit post-sunset flag (roughly 19:00-24:00 local)
    post_sunset = ((lh >= 19.0) & (lh <= 24.0)).astype(float)

    # equinox proximity: peaks near day 80 (late Mar) and 266 (late Sep)
    eq1 = np.exp(-((doy - 80.0) ** 2) / (2 * 30.0 ** 2))
    eq2 = np.exp(-((doy - 266.0) ** 2) / (2 * 30.0 ** 2))
    equinox = np.maximum(eq1, eq2)

    return np.column_stack([
        hour_sin, hour_cos, doy_sin, doy_cos,
        post_sunset, equinox,
        f / 200.0,        # rough normalisation
        k / 9.0,
    ])


FEATURE_NAMES = [
    "hour_sin", "hour_cos", "doy_sin", "doy_cos",
    "post_sunset", "equinox", "f107_norm", "kp_norm",
]


# --------------------------------------------------------------------------
# Event-wise splitting
# --------------------------------------------------------------------------
def event_split(event_ids, test_frac=0.2, val_frac=0.2, seed=0):
    """
    Split by EVENT, never by sample.

    Two samples from the same scintillation event are not independent. If one
    lands in train and the other in test, the model has effectively seen the
    answer. This is the single most common way to get a validation score that
    means nothing.
    """
    rng = np.random.default_rng(seed)
    events = np.unique(event_ids)
    rng.shuffle(events)

    n = len(events)
    n_test = max(1, int(round(n * test_frac)))
    n_val = max(1, int(round(n * val_frac)))

    test_ev = set(events[:n_test])
    val_ev = set(events[n_test:n_test + n_val])
    train_ev = set(events[n_test + n_val:])

    idx = np.arange(len(event_ids))
    return (
        idx[np.isin(event_ids, list(train_ev))],
        idx[np.isin(event_ids, list(val_ev))],
        idx[np.isin(event_ids, list(test_ev))],
    )


# --------------------------------------------------------------------------
# Metrics — the only ones that matter here
# --------------------------------------------------------------------------
def evaluate(y_true, y_pred, label=""):
    """
    Report per-class precision / recall / F1 and the confusion matrix.

    Accuracy is printed only so it can be seen NOT to matter: the majority
    baseline will score high on it while being useless.
    """
    from sklearn.metrics import (precision_recall_fscore_support,
                                 confusion_matrix, accuracy_score)

    acc = accuracy_score(y_true, y_pred)
    p, r, f1, sup = precision_recall_fscore_support(
        y_true, y_pred, labels=[0, 1, 2], zero_division=0)

    print("\n--- %s ---" % label)
    print("  accuracy: %.3f   <-- ignore this, see SEVERE recall" % acc)
    print("  class      prec    rec     F1     n")
    for i, name in enumerate(CLASS_NAMES):
        print("  %-9s %.3f  %.3f  %.3f  %4d"
              % (name, p[i], r[i], f1[i], sup[i]))

    cm = confusion_matrix(y_true, y_pred, labels=[0, 1, 2])
    print("  confusion (rows=true, cols=pred):")
    for i, row in enumerate(cm):
        print("    %-9s %s" % (CLASS_NAMES[i], " ".join("%4d" % v for v in row)))

    return {
        "accuracy": float(acc),
        "severe_precision": float(p[SEVERE]),
        "severe_recall": float(r[SEVERE]),
        "severe_f1": float(f1[SEVERE]),
        "macro_f1": float(np.mean(f1)),
    }


# --------------------------------------------------------------------------
# Baselines
# --------------------------------------------------------------------------
def run_baselines(X, y, event_ids, seed=0, out_json=None):
    """
    X          : (n_samples, n_features) feature matrix
    y          : (n_samples,) class labels 0/1/2
    event_ids  : (n_samples,) event identifier for event-wise splitting
    """
    from sklearn.linear_model import LogisticRegression
    from sklearn.ensemble import HistGradientBoostingClassifier
    from sklearn.preprocessing import StandardScaler

    tr, va, te = event_split(event_ids, seed=seed)
    print("split: %d train / %d val / %d test samples"
          % (len(tr), len(va), len(te)))
    print("       %d / %d / %d distinct events"
          % (len(np.unique(event_ids[tr])),
             len(np.unique(event_ids[va])),
             len(np.unique(event_ids[te]))))

    counts = np.bincount(y, minlength=3)
    print("class balance: NOMINAL=%d DEGRADED=%d SEVERE=%d (SEVERE = %.1f%%)"
          % (counts[0], counts[1], counts[2],
             100.0 * counts[2] / max(len(y), 1)))

    results = {}

    # --- 0. majority class: the trap ---------------------------------------
    maj = np.bincount(y[tr], minlength=3).argmax()
    results["majority"] = evaluate(
        y[te], np.full(len(te), maj),
        "BASELINE 0: majority class (predict %s always)" % CLASS_NAMES[maj])

    # --- 1. logistic regression, class-weighted ----------------------------
    sc = StandardScaler().fit(X[tr])
    lr = LogisticRegression(max_iter=2000, class_weight="balanced")
    lr.fit(sc.transform(X[tr]), y[tr])
    results["logreg"] = evaluate(
        y[te], lr.predict(sc.transform(X[te])),
        "BASELINE 1: logistic regression (class-weighted)")

    # --- 2. gradient boosting ----------------------------------------------
    # HistGradientBoosting stands in for XGBoost — same family, ships with
    # sklearn. Swap in XGBoost if it is available; results are comparable.
    gb = HistGradientBoostingClassifier(
        max_iter=300, learning_rate=0.1, max_depth=6, random_state=seed)
    gb.fit(X[tr], y[tr])
    results["gradient_boosting"] = evaluate(
        y[te], gb.predict(X[te]),
        "BASELINE 2: gradient boosting")

    # --- summary ------------------------------------------------------------
    print("\n" + "=" * 62)
    print("THE BAR THE LSTM MUST BEAT")
    print("=" * 62)
    print("  model                 SEVERE prec  SEVERE rec  SEVERE F1")
    for name, m in results.items():
        print("  %-20s   %.3f       %.3f       %.3f"
              % (name, m["severe_precision"], m["severe_recall"],
                 m["severe_f1"]))
    best = max(results.items(), key=lambda kv: kv[1]["severe_f1"])
    print("\n  best baseline: %s, SEVERE F1 = %.3f"
          % (best[0], best[1]["severe_f1"]))
    print("  the LSTM must exceed this to justify the accelerator.")
    print("=" * 62)

    if out_json:
        os.makedirs(os.path.dirname(out_json) or ".", exist_ok=True)
        with open(out_json, "w") as f:
            json.dump(results, f, indent=2)
        print("\nwritten to %s" % out_json)

    return results


# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------
def from_dataset(path, seed=0, out_json=None):
    """
    Load a dataset produced by phase_screen.py --dataset.

    That dataset is (n, seq_len, 2) sequences of [S4, sigma_phi]. For the
    baselines we flatten to summary features — the point is to establish what
    a NON-sequential model achieves, so the LSTM's advantage (if any) is
    attributable to the temporal modelling.
    """
    d = np.load(path)
    X_seq, y = d["X"], d["y"]

    s4 = X_seq[:, :, 0]
    sphi = X_seq[:, :, 1]

    # Summary statistics only — deliberately no sequence structure.
    X = np.column_stack([
        s4.mean(1), s4.std(1), s4.max(1), s4[:, -1],
        sphi.mean(1), sphi.std(1), sphi.max(1), sphi[:, -1],
        s4[:, -1] - s4[:, 0],          # crude trend
        sphi[:, -1] - sphi[:, 0],
    ])

    # phase_screen.py generates one sample per event
    event_ids = np.arange(len(y))

    print("loaded %s: %d samples, %d features" % (path, len(y), X.shape[1]))
    return run_baselines(X, y, event_ids, seed=seed, out_json=out_json)


def demo(seed=0):
    """
    Self-contained demo with synthetic climatology data, so the harness can be
    exercised before any real or generated dataset exists.

    Occurrence probability is built from the known physical drivers: strongly
    post-sunset, equinoctial maxima, rising with solar and geomagnetic
    activity. Deliberately imbalanced, to show what that does to accuracy.
    """
    rng = np.random.default_rng(seed)
    n_events = 800
    per_event = 6

    rows, labels, ev_ids = [], [], []

    for ev in range(n_events):
        lh0 = rng.uniform(0, 24)
        doy = rng.uniform(1, 365)
        f107 = rng.uniform(70, 200)
        kp = rng.uniform(0, 7)

        for j in range(per_event):
            lh = (lh0 + j * 0.25) % 24

            post_sunset = 1.0 if 19 <= lh <= 24 else 0.0
            eq = max(np.exp(-((doy - 80) ** 2) / (2 * 30 ** 2)),
                     np.exp(-((doy - 266) ** 2) / (2 * 30 ** 2)))
            drive = (0.75 * post_sunset + 0.5 * eq
                     + 0.3 * (f107 - 70) / 130.0 + 0.2 * kp / 9.0)

            p_sev = np.clip(0.35 * drive - 0.10, 0.0, 0.9)
            p_deg = np.clip(0.45 * drive - 0.03, 0.0, 0.9)

            u = rng.random()
            if u < p_sev:
                lab = 2
            elif u < p_sev + p_deg:
                lab = 1
            else:
                lab = 0

            rows.append((lh, doy, f107, kp))
            labels.append(lab)
            ev_ids.append(ev)

    rows = np.array(rows)
    X = climatology_features(rows[:, 0], rows[:, 1], rows[:, 2], rows[:, 3])
    y = np.array(labels)
    ev_ids = np.array(ev_ids)

    print("DEMO: synthetic climatology-driven occurrence")
    print("features:", ", ".join(FEATURE_NAMES))
    return run_baselines(X, y, ev_ids, seed=seed)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", help="scint_dataset.npz from phase_screen.py")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", help="write metrics JSON here")
    args = ap.parse_args()

    if args.demo:
        demo(seed=args.seed)
    elif args.data:
        from_dataset(args.data, seed=args.seed, out_json=args.out)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
