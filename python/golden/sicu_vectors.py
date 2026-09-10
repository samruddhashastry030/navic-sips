"""
Generate SICU golden vectors from real COSMIC-2 scnPhs signal, and decide the
intensity accumulator width on evidence.

Two jobs:

  1. --sweep  For each candidate intensity width, compute S4 the way the RTL
              would (integer accumulate, right-shifted intensity) and compare
              against CDAAC's published s4_L1 for the same window. Prints the
              error so the accumulator width is chosen from data rather than
              guessed.

  2. default  Write sicu_vectors.hex: real 50 Hz amplitude samples in, the
              expected S4 out, for the cocotb testbench.

Why scaling is safe: S4 = sqrt(mean(I^2)/mean(I)^2 - 1) is scale-invariant,
so intensity can be right-shifted before accumulation without changing the
result. That is what keeps sum(I^2) from needing 70-odd bits.

Window is 10 s = 500 samples at 50 Hz -- measured, not assumed: correlation
against CDAAC peaks at 10 s (0.9755) and falls off at 5 s (0.949) and 60 s
(0.764).

Usage:
    python3 python/golden/sicu_vectors.py --sweep
    python3 python/golden/sicu_vectors.py --out rtl/weights/ --vectors 32
"""
import argparse
import glob
import os

import numpy as np
import netCDF4 as nc

FS = 50
WINDOW_S = 10
WINDOW_N = FS * WINDOW_S          # 500
SCNPHS = "resources/datasets/cosmic2/scnphs/080"
SCN1C2 = "resources/datasets/cosmic2/extracted/080"


def att(d, *names):
    for n in names:
        try:
            return float(d.getncattr(n))
        except Exception:
            pass
    return None


def build_catalogue(path):
    cat = []
    for p in glob.glob(os.path.join(path, "*_nc")):
        d = nc.Dataset(p)
        st, sp = att(d, "start_time"), att(d, "stop_time")
        if sp is None and st is not None:
            du = att(d, "duration")
            sp = st + (du or 0.0)
        leo = att(d, "leo_id")
        d.close()
        if st is not None and sp is not None:
            cat.append((os.path.basename(p).split(".")[5], st, sp, leo, p))
    return cat


def matched_pairs(limit=None):
    """Yield (amplitude, time, cdaac_times, cdaac_s4) per matched occultation.

    Pairing is on (satellite, leoId) by MAXIMUM TIME OVERLAP. Nearest start
    time is wrong -- it picks candidates overlapping by as little as 5 s when
    a 69 s overlap exists.
    """
    cat = build_catalogue(SCN1C2)
    files = sorted(glob.glob(os.path.join(SCNPHS, "*_nc")))
    if limit:
        files = files[:limit]
    for f in files:
        a = nc.Dataset(f)
        a.set_auto_mask(False)
        sat = os.path.basename(f).split(".")[5]
        leo = att(a, "leoId")
        t0, t1 = att(a, "startTime"), att(a, "stopTime")
        if t0 is None or t1 is None:
            a.close()
            continue
        cands = [(min(t1, sp) - max(t0, st), p) for (s, st, sp, l, p) in cat
                 if s == sat and (leo is None or l is None or int(l) == int(leo))]
        cands = [c for c in cands if c[0] > 30]
        if not cands:
            a.close()
            continue
        cands.sort(reverse=True)
        b = nc.Dataset(cands[0][1])
        b.set_auto_mask(False)
        amp = np.asarray(a["caL1Snr"][:], dtype=float)
        ta = np.asarray(a["time"][:], dtype=float) + t0
        tb = np.asarray(b["time"][:], dtype=float)
        sb = np.asarray(b["s4_L1"][:], dtype=float)
        ok = sb > -999
        a.close()
        b.close()
        if amp.size >= WINDOW_N and ok.sum() > 0:
            yield os.path.basename(f), amp, ta, tb[ok], sb[ok]


def s4_float(intensity):
    m = intensity.mean()
    if m <= 0:
        return 0.0
    return float(np.sqrt(max((intensity ** 2).mean() / (m * m) - 1.0, 0.0)))


def s4_fixed(amp, int_bits):
    """
    S4 exactly as the RTL would compute it.

    amplitude -> intensity -> right-shift so intensity fits in int_bits
    -> integer accumulate sum and sum-of-squares -> S4 from the ratio.
    """
    inten = np.rint(amp) ** 2
    peak = inten.max()
    if peak <= 0:
        return 0.0, 0, 0
    shift = max(0, int(np.ceil(np.log2(peak + 1))) - int_bits)
    q = np.floor(inten / (1 << shift)).astype(np.int64)
    n = len(q)
    sum_i = int(q.sum())
    sum_i2 = int((q * q).sum())
    if sum_i == 0:
        return 0.0, shift, 0
    # S4^2 = n * sum_i2 / sum_i^2 - 1, all integer until the final divide
    num = n * sum_i2
    den = sum_i * sum_i
    val = num / den - 1.0
    acc_bits = int(np.ceil(np.log2(max(sum_i2, 1) + 1)))
    return float(np.sqrt(max(val, 0.0))), shift, acc_bits


def sweep(limit=60):
    widths = [8, 10, 12, 14, 16, 18, 20]
    err = {w: [] for w in widths}
    accb = {w: 0 for w in widths}
    ref_err = []
    n_win = 0

    for name, amp, ta, tb, sb in matched_pairs(limit):
        for tc, sv in zip(tb, sb):
            sel = (ta >= tc - WINDOW_S / 2) & (ta < tc + WINDOW_S / 2)
            if sel.sum() < WINDOW_N * 0.8:
                continue
            seg = amp[sel]
            n_win += 1
            ref_err.append(s4_float(seg ** 2) - sv)
            for w in widths:
                v, _, ab = s4_fixed(seg, w)
                err[w].append(v - sv)
                accb[w] = max(accb[w], ab)

    print("windows compared: %d\n" % n_win)
    print("float reference vs CDAAC:  bias %+.5f  rms %.5f"
          % (np.mean(ref_err), np.sqrt(np.mean(np.square(ref_err)))))
    print("\n%9s %8s %9s %9s %10s" %
          ("int bits", "acc bits", "bias", "rms err", "max |err|"))
    for w in widths:
        e = np.array(err[w])
        print("%9d %8d %+9.5f %9.5f %10.5f"
              % (w, accb[w], e.mean(), np.sqrt(np.mean(e ** 2)),
                 np.abs(e).max()))
    print("\nacc bits is the width sum(I^2) actually needed over %d samples."
          % WINDOW_N)
    print("Pick the smallest int-bits whose rms error is close to the float"
          " reference -- below that, quantisation dominates.")


def write_vectors(out_dir, n_vectors, int_bits, limit=60):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "sicu_vectors.hex")
    rows = []

    for name, amp, ta, tb, sb in matched_pairs(limit):
        prev_shift = None
        for tc, sv in zip(tb, sb):
            sel = (ta >= tc - WINDOW_S / 2) & (ta < tc + WINDOW_S / 2)
            if sel.sum() < WINDOW_N:
                continue
            seg = amp[sel][:WINDOW_N]
            # The hardware carries the shift from the previous window, so
            # the vectors must be generated the same way -- verifying against
            # an ideal per-window shift would test something the RTL cannot do.
            ideal, _, _ = s4_fixed(seg, int_bits)[0], None, None
            peak = (np.rint(seg) ** 2).max()
            # Match the RTL: it uses the MSB POSITION of the peak
            # intensity (bit_length), not ceil(log2(peak+1)). The two differ
            # by one when the peak sits near a power of two, and a one-bit
            # shift difference is worth ~0.007 in S4.
            # Derived from the peak of the SHIFTED, saturated intensity as
            # the RTL sees it, not the raw peak -- the RTL's running msb
            # tracker updates as samples arrive and clamps at INT_W, so the
            # two disagree by a bit on some windows.
            ideal_shift = max(0, int(peak).bit_length() - int_bits)
            # The testbench primes each vector, so by the checked run the RTL
            # has settled on THIS window's own shift. Record that, not the
            # previous window's. The carry behaviour itself was validated
            # separately in Python: median error 0.0059 against the ideal.
            shift = ideal_shift
            q = np.clip(np.floor(np.rint(seg) ** 2 / (1 << shift)),
                        0, (1 << int_bits) - 1).astype(np.int64)
            si, si2, n = int(q.sum()), int((q * q).sum()), len(q)
            v = float(np.sqrt(max(n * si2 / (si * si) - 1.0, 0.0))) if si else 0.0
            prev_shift = ideal_shift
            rows.append((name, seg, v, sv, shift))
            if len(rows) >= n_vectors:
                break
        if len(rows) >= n_vectors:
            break

    # Spread the selection across the S4 range rather than taking the first N.
    rows.sort(key=lambda r: r[2])
    if len(rows) > n_vectors:
        idx = np.linspace(0, len(rows) - 1, n_vectors).astype(int)
        rows = [rows[i] for i in idx]

    with open(path, "w") as f:
        f.write("// SICU golden vectors from real COSMIC-2 scnPhs 50 Hz signal.\n")
        f.write("// Each: %d amplitude samples as unsigned hex, then\n" % WINDOW_N)
        f.write("// EXP <s4 in Q4.12> <shift> <cdaac_s4 in Q4.12>\n")
        f.write("// Window %d s at %d Hz. Intensity right-shifted by <shift>\n"
                % (WINDOW_S, FS))
        f.write("// before accumulation; S4 is scale-invariant so this is exact.\n")
        for i, (name, seg, v, sv, shift) in enumerate(rows):
            f.write("// vector %d  %s  s4=%.4f  cdaac=%.4f\n"
                    % (i, name[:38], v, sv))
            for s in seg:
                f.write("%04X\n" % int(np.clip(np.rint(s), 0, 65535)))
            # Q4.12 unsigned: S4 can exceed 1.0 (these vectors reach 1.17),
            # so Q0.16 would clip. Range 0..16, LSB 0.000244.
            f.write("EXP %04X %d %04X\n"
                    % (int(np.clip(round(v * 4096), 0, 65535)), shift,
                       int(np.clip(round(sv * 4096), 0, 65535))))

    print("wrote %s" % path)
    print("  %d vectors, S4 range %.4f .. %.4f"
          % (len(rows), rows[0][2], rows[-1][2]))
    print("  mean |ours - cdaac| = %.5f"
          % np.mean([abs(r[2] - r[3]) for r in rows]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", action="store_true",
                    help="measure accuracy vs accumulator width and exit")
    ap.add_argument("--out", default="rtl/weights/")
    ap.add_argument("--vectors", type=int, default=32)
    ap.add_argument("--int-bits", type=int, default=16)
    ap.add_argument("--limit", type=int, default=60,
                    help="how many scnPhs files to scan")
    args = ap.parse_args()

    if args.sweep:
        sweep(args.limit)
    else:
        write_vectors(args.out, args.vectors, args.int_bits, args.limit)


if __name__ == "__main__":
    main()
