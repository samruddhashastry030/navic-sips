"""
Build an LSTM training set from COSMIC-2 scn1c2 occultations.

Mirrors phase_screen.py --dataset output format so python/ml/baseline.py
can consume it unchanged:
    X : (n, seq_len, 2) float32  -- [S4_L1, S4_L2] over consecutive 10 s windows
    y : (n,) int64               -- class at horizon into the future

scn1c2 has a native 10 s cadence, so window_s is fixed at 10 s and no
re-windowing is needed. sigma_phi is unusable in this product (valid in
~0.7% of files), so S4_L2 takes the second feature slot.

Usage:
    python3 python/golden/cosmic2_dataset.py \
        --root resources/datasets/cosmic2/day080 \
        --out sim/vectors_cosmic2/

    # no geographic / local-time filtering (much larger set)
    python3 python/golden/cosmic2_dataset.py --root <dir> --out <dir> \
        --all-regions --all-hours
"""
import argparse
import glob
import json
import os

import numpy as np
import netCDF4 as nc

# Same thresholds as phase_screen.py -- keep these in sync or the two
# datasets are not comparable.
CLASS_THRESHOLDS = {"NOMINAL": 0.2, "DEGRADED": 0.5}
FILL = -999.0
CADENCE_S = 10.0


def classify(s4):
    if s4 < CLASS_THRESHOLDS["NOMINAL"]:
        return 0    # NOMINAL
    if s4 < CLASS_THRESHOLDS["DEGRADED"]:
        return 1    # DEGRADED
    return 2        # SEVERE


def attr(dataset, *names):
    """First finite, non-fill global attribute from names, else None."""
    for name in names:
        value = getattr(dataset, name, None)
        if value is None:
            continue
        try:
            value = float(value)
        except (TypeError, ValueError):
            continue
        if np.isfinite(value) and value != FILL:
            return value
    return None


def read_occultation(path):
    dataset = nc.Dataset(path)
    dataset.set_auto_mask(False)
    try:
        s4_l1 = np.asarray(dataset["s4_L1"][:], dtype=float)
        s4_l2 = np.asarray(dataset["s4_L2"][:], dtype=float)
        meta = {
            "lat": attr(dataset, "lat_s4max_L1", "lat_start"),
            "lon": attr(dataset, "lon_s4max_L1", "lon_start"),
            "lct": attr(dataset, "lct_s4max_L1", "lct_start"),
            "s4max": attr(dataset, "s4max_L1"),
            "prn": getattr(dataset, "prn_id", None),
        }
    finally:
        dataset.close()

    bad = (s4_l1 <= FILL) | (s4_l2 <= FILL)
    bad |= ~np.isfinite(s4_l1) | ~np.isfinite(s4_l2)
    s4_l1[bad] = np.nan
    s4_l2[bad] = np.nan
    return s4_l1, s4_l2, meta


def in_region(meta, lon_lo, lon_hi, lat_abs):
    if meta["lon"] is None or meta["lat"] is None:
        return False
    return lon_lo <= meta["lon"] <= lon_hi and abs(meta["lat"]) <= lat_abs


def post_sunset(meta, lct_lo, lct_hi):
    if meta["lct"] is None:
        return False
    hour = meta["lct"] % 24.0
    if lct_lo <= lct_hi:
        return lct_lo <= hour <= lct_hi
    # window wraps midnight, e.g. 19:00 -> 02:00
    return hour >= lct_lo or hour <= lct_hi


def build(root, out_dir, seq_len=32, horizon_s=30.0, stride=5,
          lon_lo=65.0, lon_hi=95.0, lat_abs=30.0,
          lct_lo=19.0, lct_hi=2.0,
          region_filter=True, night_filter=True):
    horizon_win = int(round(horizon_s / CADENCE_S))
    need = seq_len + horizon_win

    samples_x = []
    samples_y = []
    event_ids = []
    meta_rows = []

    files = sorted(glob.glob(os.path.join(root, "**", "*_nc"), recursive=True))
    if not files:
        files = sorted(glob.glob(os.path.join(root, "**", "*.nc"), recursive=True))
    kept_occultations = 0

    for ev_idx, path in enumerate(files):
        try:
            s4_l1, s4_l2, meta = read_occultation(path)
        except Exception:
            continue

        if region_filter and not in_region(meta, lon_lo, lon_hi, lat_abs):
            continue
        if night_filter and not post_sunset(meta, lct_lo, lct_hi):
            continue
        if len(s4_l1) < need:
            continue

        used = 0
        for start in range(0, len(s4_l1) - need + 1, stride):
            win_l1 = s4_l1[start:start + seq_len]
            win_l2 = s4_l2[start:start + seq_len]
            target = s4_l1[start + seq_len + horizon_win - 1]
            if np.isnan(win_l1).any() or np.isnan(win_l2).any():
                continue
            if np.isnan(target):
                continue

            label = classify(target)
            samples_x.append(np.stack([win_l1, win_l2], axis=1))
            samples_y.append(label)
            event_ids.append(ev_idx)
            meta_rows.append({
                "event": ev_idx,
                "file": os.path.basename(path),
                "lat": meta["lat"],
                "lon": meta["lon"],
                "lct": meta["lct"],
                "s4_target": float(target),
                "label": int(label),
            })
            used += 1

        if used:
            kept_occultations += 1

    if not samples_x:
        raise SystemExit(
            "no samples built - loosen the filters "
            "(try --all-regions and/or --all-hours)"
        )

    x = np.array(samples_x, dtype=np.float32)
    y = np.array(samples_y, dtype=np.int64)
    events = np.array(event_ids, dtype=np.int64)

    os.makedirs(out_dir, exist_ok=True)
    np.savez_compressed(
        os.path.join(out_dir, "cosmic2_dataset.npz"),
        X=x, y=y, event_ids=events,
    )

    counts = np.bincount(y, minlength=3)
    with open(os.path.join(out_dir, "cosmic2_dataset_meta.json"), "w") as handle:
        json.dump({
            "source": "COSMIC-2 scn1c2",
            "features": ["s4_L1", "s4_L2"],
            "cadence_s": CADENCE_S,
            "seq_len": seq_len,
            "horizon_s": horizon_s,
            "stride": stride,
            "thresholds": CLASS_THRESHOLDS,
            "region": {
                "lon": [lon_lo, lon_hi],
                "lat_abs": lat_abs,
                "lct": [lct_lo, lct_hi],
                "region_filter": region_filter,
                "night_filter": night_filter,
            },
            "files_scanned": len(files),
            "occultations_used": kept_occultations,
            "samples": int(len(y)),
            "class_counts": {
                "NOMINAL": int(counts[0]),
                "DEGRADED": int(counts[1]),
                "SEVERE": int(counts[2]),
            },
            "rows": meta_rows[:2000],
        }, handle, indent=2)

    print("files scanned:      %d" % len(files))
    print("occultations used:  %d" % kept_occultations)
    print("dataset: X%s  y%s" % (x.shape, y.shape))
    print("class counts: NOMINAL=%d DEGRADED=%d SEVERE=%d (SEVERE = %.1f%%)"
          % (counts[0], counts[1], counts[2], 100.0 * counts[2] / len(y)))
    print("written to %s" % out_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True,
                        help="directory of extracted scn1c2 *_nc files")
    parser.add_argument("--out", default="sim/vectors_cosmic2/")
    parser.add_argument("--seq-len", type=int, default=32)
    parser.add_argument("--horizon-s", type=float, default=30.0)
    parser.add_argument("--stride", type=int, default=5,
                        help="window step in 10 s samples; 5 = 50 s apart")
    parser.add_argument("--lon-lo", type=float, default=65.0)
    parser.add_argument("--lon-hi", type=float, default=95.0)
    parser.add_argument("--lat-abs", type=float, default=30.0)
    parser.add_argument("--all-regions", action="store_true",
                        help="disable the geographic filter")
    parser.add_argument("--all-hours", action="store_true",
                        help="disable the post-sunset local-time filter")
    args = parser.parse_args()

    build(args.root, args.out,
          seq_len=args.seq_len,
          horizon_s=args.horizon_s,
          stride=args.stride,
          lon_lo=args.lon_lo,
          lon_hi=args.lon_hi,
          lat_abs=args.lat_abs,
          region_filter=not args.all_regions,
          night_filter=not args.all_hours)


if __name__ == "__main__":
    main()
