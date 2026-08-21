#!/usr/bin/env python3
"""
NavIC-SIPS — SICU golden model.

WHAT THE SICU DOES
------------------
It consumes POST-CORRELATION prompt I/Q from the host receiver's tracking
channel and produces the two scintillation indices.

  intensity  I = I_p^2 + Q_p^2
  phase      phi = atan2(Q_p, I_p)      (CORDIC in hardware)

  S4        = sqrt( (<I^2> - <I>^2) / <I>^2 )
  sigma_phi = std( highpass_detrend(phi) )

IT DOES NOT CONSUME RAW FRONT-END I/Q. Raw front-end output is
pre-correlation: every satellite mixed together, each below the noise floor.
Per-satellite amplitude and carrier phase do not exist until after
despreading and tracking. This is the single most important correction to
the original proposal.

WHY STREAMING
-------------
S4 needs only running sums, not a stored window:

    S4^2 = (sum(I^2)/N - (sum(I)/N)^2) / (sum(I)/N)^2

Two accumulators and a counter. No 1024-sample buffer, no ping-pong SRAM.
Same for sigma_phi once the detrending filter state is carried.

This is the reference the RTL must match BIT-EXACTLY. Generate vectors from
here and hand them to verification as the acceptance criterion — do not
defer this to the verification phase.

FIXED-POINT
-----------
The Q-format choices below are PLACEHOLDERS pending two measurements:
  - realistic prompt I/Q magnitude range (from the Mendeley dataset or a
    tracker run)
  - S4 dynamic range in the generated dataset
Both are open items in the architecture spec. Do not freeze the RTL scaling
until they are measured.

USAGE
    python3 scint_indices.py --selftest
    python3 scint_indices.py --vectors --out ../../sim/vectors/
"""

import argparse
import json
import os

import numpy as np

# --------------------------------------------------------------------------
# Configuration — mirrors the architecture spec
# --------------------------------------------------------------------------
PROMPT_RATE_HZ = 1000.0     # prompt I/Q input rate from the tracking channel
DECIMATED_HZ = 50.0         # internal rate for index computation
WINDOW_SHORT_S = 10.0       # SICU short integration window
WINDOW_LONG_S = 60.0        # SICU long window — the conventional S4 window

DETREND_CUTOFF_HZ = 0.1     # VERIFY vs primary ISM receiver spec (Track A)
DETREND_ORDER = 6           # VERIFY

# Fixed-point formats — PLACEHOLDERS, see module docstring
Q_IQ = 15                   # prompt I/Q fractional bits (16-bit signed)
Q_S4 = 14                   # S4 output fractional bits
Q_SPHI = 12                 # sigma_phi output fractional bits
ACC_BITS = 48               # accumulator width for sum(I^2)


# --------------------------------------------------------------------------
# Streaming index accumulator — the hardware reference
# --------------------------------------------------------------------------
class StreamingS4:
    """
    Running S4 over a fixed-length window.

    Hardware mapping:
        sum_i    -> accumulator register
        sum_i2   -> wider accumulator register
        n        -> sample counter
    One multiply-accumulate per sample. No sample storage.
    """

    def __init__(self):
        self.reset()

    def reset(self):
        self.sum_i = 0.0
        self.sum_i2 = 0.0
        self.n = 0

    def update(self, i_p, q_p):
        """Feed one prompt I/Q pair."""
        intensity = float(i_p) * float(i_p) + float(q_p) * float(q_p)
        self.sum_i += intensity
        self.sum_i2 += intensity * intensity
        self.n += 1
        return intensity

    def value(self):
        if self.n == 0:
            return 0.0
        mean_i = self.sum_i / self.n
        if mean_i <= 0.0:
            return 0.0
        mean_i2 = self.sum_i2 / self.n
        var = (mean_i2 - mean_i * mean_i) / (mean_i * mean_i)
        return float(np.sqrt(max(var, 0.0)))


class StreamingSigmaPhi:
    """
    Running sigma_phi over a fixed-length window.

    Carries:
      - phase unwrap state (previous raw phase, cycle count)
      - IIR high-pass filter state
      - sum and sum-of-squares of the detrended phase

    The unwrapper is a known source of subtle bugs. Test it explicitly with
    phase sequences that cross +/-pi repeatedly.
    """

    def __init__(self, fs=DECIMATED_HZ, cutoff=DETREND_CUTOFF_HZ,
                 order=DETREND_ORDER):
        self.fs = fs
        self.cutoff = cutoff
        self.order = order
        self._make_filter()
        self.reset()

    def _make_filter(self):
        try:
            from scipy.signal import butter
            nyq = self.fs / 2.0
            wn = self.cutoff / nyq
            self.b, self.a = butter(self.order, wn, btype="highpass")
            self.have_filter = True
        except ImportError:
            self.b = self.a = None
            self.have_filter = False

    def reset(self):
        self.prev_raw = None
        self.cycles = 0
        self.samples = []          # only for the batch reference path
        self.sum_p = 0.0
        self.sum_p2 = 0.0
        self.n = 0

    def update(self, i_p, q_p):
        raw = float(np.arctan2(float(q_p), float(i_p)))
        if self.prev_raw is not None:
            d = raw - self.prev_raw
            if d > np.pi:
                self.cycles -= 1
            elif d < -np.pi:
                self.cycles += 1
        self.prev_raw = raw
        unwrapped = raw + 2.0 * np.pi * self.cycles
        self.samples.append(unwrapped)
        self.n += 1
        return unwrapped

    def value(self):
        if self.n < 2:
            return 0.0
        phase = np.asarray(self.samples)
        if self.have_filter and self.n > 3 * self.order:
            from scipy.signal import filtfilt
            detrended = filtfilt(self.b, self.a, phase)
        else:
            # Linear detrend fallback — NOT equivalent to the high-pass.
            idx = np.arange(self.n)
            detrended = phase - np.polyval(np.polyfit(idx, phase, 1), idx)
        return float(np.std(detrended))


# --------------------------------------------------------------------------
# Fixed-point helpers
# --------------------------------------------------------------------------
def to_fixed(x, frac_bits, width=16, signed=True):
    """Quantise a float to a fixed-point integer, with saturation."""
    scaled = int(np.round(np.asarray(x) * (1 << frac_bits)))
    if signed:
        lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    else:
        lo, hi = 0, (1 << width) - 1
    return int(np.clip(scaled, lo, hi))


def from_fixed(x, frac_bits):
    return float(x) / (1 << frac_bits)


# --------------------------------------------------------------------------
# Batch reference (for cross-checking the streaming path)
# --------------------------------------------------------------------------
def batch_s4(i_p, q_p):
    intensity = np.asarray(i_p, float) ** 2 + np.asarray(q_p, float) ** 2
    m = intensity.mean()
    if m <= 0:
        return 0.0
    return float(np.sqrt(max((intensity ** 2).mean() / (m * m) - 1.0, 0.0)))


def batch_sigma_phi(i_p, q_p, fs=DECIMATED_HZ):
    phase = np.unwrap(np.arctan2(np.asarray(q_p, float),
                                 np.asarray(i_p, float)))
    try:
        from scipy.signal import butter, filtfilt
        b, a = butter(DETREND_ORDER, DETREND_CUTOFF_HZ / (fs / 2.0),
                      btype="highpass")
        return float(np.std(filtfilt(b, a, phase)))
    except ImportError:
        idx = np.arange(len(phase))
        return float(np.std(phase - np.polyval(np.polyfit(idx, phase, 1), idx)))


# --------------------------------------------------------------------------
# Test vector generation for the RTL testbench
# --------------------------------------------------------------------------
def make_vectors(out_dir, n_cases=8, window_s=WINDOW_SHORT_S,
                 fs=DECIMATED_HZ, seed=0):
    """
    Generate prompt I/Q stimulus + expected S4/sigma_phi for cocotb.

    Emits:
      sicu_vectors.json  -- human-readable, with metadata
      sicu_iq.hex        -- I/Q pairs, one per line, for $readmemh
      sicu_expected.txt  -- expected outputs per case
    """
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from phase_screen import generate_event

    rng = np.random.default_rng(seed)
    os.makedirs(out_dir, exist_ok=True)

    rms_sweep = np.linspace(0.05, 3.0, n_cases)
    cases = []
    iq_lines = []
    exp_lines = []

    for idx, rms in enumerate(rms_sweep):
        ev = generate_event(duration_s=window_s, fs=fs,
                            rms_phase=float(rms), rng=rng)
        amplitude = np.sqrt(ev["I"])
        i_p = amplitude * np.cos(ev["phase"])
        q_p = amplitude * np.sin(ev["phase"])

        # Scale into the 16-bit signed range with headroom
        peak = max(np.max(np.abs(i_p)), np.max(np.abs(q_p)), 1e-12)
        scale = 0.7 / peak
        i_s, q_s = i_p * scale, q_p * scale

        s4_stream = StreamingS4()
        sphi_stream = StreamingSigmaPhi(fs=fs)
        for a, b in zip(i_s, q_s):
            s4_stream.update(a, b)
            sphi_stream.update(a, b)

        s4_s = s4_stream.value()
        s4_b = batch_s4(i_s, q_s)
        sphi_s = sphi_stream.value()
        sphi_b = batch_sigma_phi(i_s, q_s, fs)

        assert abs(s4_s - s4_b) < 1e-9, "streaming/batch S4 mismatch"

        for a, b in zip(i_s, q_s):
            iq_lines.append("%04x %04x" % (
                to_fixed(a, Q_IQ) & 0xFFFF,
                to_fixed(b, Q_IQ) & 0xFFFF,
            ))

        exp_lines.append("%d %04x %04x" % (
            idx,
            to_fixed(s4_s, Q_S4, width=16, signed=False) & 0xFFFF,
            to_fixed(sphi_s, Q_SPHI, width=16, signed=False) & 0xFFFF,
        ))

        cases.append({
            "case": idx,
            "rms_phase": float(rms),
            "n_samples": int(len(i_s)),
            "s4": s4_s,
            "s4_fixed": to_fixed(s4_s, Q_S4, 16, False),
            "sigma_phi": sphi_s,
            "sigma_phi_fixed": to_fixed(sphi_s, Q_SPHI, 16, False),
        })

    with open(os.path.join(out_dir, "sicu_iq.hex"), "w") as f:
        f.write("\n".join(iq_lines) + "\n")
    with open(os.path.join(out_dir, "sicu_expected.txt"), "w") as f:
        f.write("\n".join(exp_lines) + "\n")
    with open(os.path.join(out_dir, "sicu_vectors.json"), "w") as f:
        json.dump({
            "window_s": window_s,
            "fs": fs,
            "q_iq": Q_IQ,
            "q_s4": Q_S4,
            "q_sphi": Q_SPHI,
            "detrend_cutoff_hz": DETREND_CUTOFF_HZ,
            "detrend_order": DETREND_ORDER,
            "note": "Fixed-point formats are placeholders pending measurement",
            "cases": cases,
        }, f, indent=2)

    return cases


def selftest():
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from phase_screen import generate_event

    rng = np.random.default_rng(7)
    print("SICU golden model self-test")
    print("streaming vs batch, 10 s windows at 50 Hz\n")
    print("  rms   S4(stream)  S4(batch)   diff     sigma_phi")
    print("  ----  ----------  ---------  --------  ---------")

    ok = True
    for rms in [0.1, 0.3, 0.6, 1.0, 2.0]:
        ev = generate_event(duration_s=10.0, fs=50.0,
                            rms_phase=rms, rng=rng)
        amp = np.sqrt(ev["I"])
        i_p = amp * np.cos(ev["phase"])
        q_p = amp * np.sin(ev["phase"])

        st = StreamingS4()
        sp = StreamingSigmaPhi(fs=50.0)
        for a, b in zip(i_p, q_p):
            st.update(a, b)
            sp.update(a, b)

        s4s, s4b = st.value(), batch_s4(i_p, q_p)
        d = abs(s4s - s4b)
        ok &= d < 1e-9
        print("  %.2f   %8.4f   %8.4f  %.2e  %8.4f"
              % (rms, s4s, s4b, d, sp.value()))

    print()
    print("streaming == batch:", "PASS" if ok else "FAIL")

    # Unwrapper check
    print("\nphase unwrap check (ramp crossing +/-pi many times)")
    n = 500
    true_phase = np.linspace(0, 20 * np.pi, n)
    i_p, q_p = np.cos(true_phase), np.sin(true_phase)
    sp = StreamingSigmaPhi(fs=50.0)
    for a, b in zip(i_p, q_p):
        sp.update(a, b)
    got = np.asarray(sp.samples)
    err = np.max(np.abs(got - true_phase))
    print("  max unwrap error: %.2e rad -> %s"
          % (err, "PASS" if err < 1e-9 else "FAIL"))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--vectors", action="store_true")
    ap.add_argument("--out", default=".")
    ap.add_argument("--n-cases", type=int, default=8)
    args = ap.parse_args()

    if args.selftest:
        selftest()
    elif args.vectors:
        cases = make_vectors(args.out, n_cases=args.n_cases)
        print("wrote %d cases to %s" % (len(cases), args.out))
        print("  sicu_iq.hex        -- $readmemh stimulus")
        print("  sicu_expected.txt  -- expected S4 / sigma_phi")
        print("  sicu_vectors.json  -- metadata")
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
