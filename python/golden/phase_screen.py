#!/usr/bin/env python3
"""
NavIC-SIPS — phase-screen ionospheric scintillation generator.

WHAT THIS IS
------------
A physics-based generator of amplitude/phase scintillation time series with
NavIC GEO/GSO geometry. This is the primary training-data source for the
LSTM, because:

  - COSMIC radio occultation sweeps the ray path through the ionosphere over
    ~2 minutes, so its temporal dynamics are dominated by geometry, not by
    ionospheric evolution. An LSTM trained on it learns the wrong thing.
  - NavIC's usable satellites are GEO/GSO: near-stationary line of sight.
    That is what we generate here.
  - Scintillation is rare (a few percent of days). We need to generate severe
    events on demand to have a trainable class balance at all.

METHOD
------
Standard single-phase-screen diffraction model:

  1. Build a 1D phase screen phi(x) with a power-law spatial PSD ~ q^(-p).
     Irregularity spectra in the equatorial F-region are commonly modelled
     with a one-dimensional spectral index p around 2.5-3.5.
  2. Impose it on a plane wave:  E0(x) = exp(i * phi(x))
  3. Fresnel-propagate to the receiver a distance z below the screen:
         E(q) = FFT[E0] * exp(-i q^2 z / 2k)
  4. Convert space to time using the irregularity drift velocity:  t = x / v
  5. Intensity I = |E|^2, phase = arg(E)

CITE, DO NOT TRUST BLINDLY
--------------------------
The single-phase-screen approach traces to Rino's work on scintillation
theory (Radio Science, 1979) and is standard in the GNSS scintillation
literature. TRACK A MUST VERIFY the parameter ranges below against a primary
source before these numbers go in the paper:
  - spectral index p for the Indian equatorial sector
  - screen height (F-region peak)
  - typical zonal drift velocity
  - the S4 vs rms-phase relationship

The defaults here are plausible, not authoritative.

USAGE
-----
    python3 phase_screen.py --demo
    python3 phase_screen.py --dataset --n-events 200 --out ../../sim/vectors/
"""

import argparse
import json
import os

import numpy as np

# --------------------------------------------------------------------------
# Physical constants / NavIC L5
# --------------------------------------------------------------------------
C_LIGHT = 299_792_458.0
F_L5 = 1176.45e6                    # NavIC L5 carrier, Hz  (verify vs ICD)
F_S = 2492.028e6                    # NavIC S band, Hz      (verify vs ICD)
LAMBDA_L5 = C_LIGHT / F_L5          # ~0.2549 m

# Default ionospheric parameters — VERIFY THESE (Track A)
DEFAULT_SCREEN_HEIGHT = 350e3       # m, F-region peak
DEFAULT_DRIFT_VELOCITY = 100.0      # m/s, eastward zonal drift
DEFAULT_SPECTRAL_INDEX = 3.0        # 1D phase PSD slope
DEFAULT_OUTER_SCALE = 1000.0        # m, irregularity outer scale L0


# --------------------------------------------------------------------------
# Core model
# --------------------------------------------------------------------------
def make_phase_screen(n, dx, p, rms_phase, rng, outer_scale=DEFAULT_OUTER_SCALE):
    """
    Generate a 1D phase screen with power-law PSD.

    n           : number of samples
    dx          : spatial sample spacing (m)
    p           : spectral index
    rms_phase   : target RMS phase in radians — the knob that sets strength
    outer_scale : L0 (m), above which the spectrum flattens

    THE OUTER SCALE IS NOT OPTIONAL. With a pure q^(-p) law and no outer
    scale, essentially all the phase variance piles up at the largest scales
    in the simulation domain. Those scales are far bigger than the Fresnel
    radius, so Fresnel propagation filters them out entirely and S4 stays
    near zero no matter how large rms_phase gets. Using the standard
    (q^2 + q0^2)^(-p/2) form puts the power where it actually causes
    diffraction, and S4 then behaves correctly: monotonic in rms_phase,
    saturating near 1 in strong scintillation.
    """
    q = 2.0 * np.pi * np.fft.fftfreq(n, d=dx)
    q0 = 2.0 * np.pi / outer_scale

    psd = (q ** 2 + q0 ** 2) ** (-p / 2.0)

    amp = np.sqrt(psd)
    rand_phase = rng.uniform(0.0, 2.0 * np.pi, n)
    spectrum = amp * np.exp(1j * rand_phase)

    phi = np.fft.ifft(spectrum).real

    # Normalise to the requested RMS. Doing it this way (rather than deriving
    # from Ck/L turbulence strength) keeps the knob interpretable and avoids
    # pretending to a calibration we have not verified.
    sd = np.std(phi)
    if sd > 0:
        phi = phi / sd * rms_phase
    return phi


def fresnel_propagate(phi, dx, z, wavelength):
    """
    Propagate the complex field exp(i*phi) a distance z below the screen.
    Returns the complex field at the receiver plane.
    """
    n = len(phi)
    k = 2.0 * np.pi / wavelength
    q = 2.0 * np.pi * np.fft.fftfreq(n, d=dx)

    e0 = np.exp(1j * phi)
    e0_q = np.fft.fft(e0)
    transfer = np.exp(-1j * (q ** 2) * z / (2.0 * k))
    return np.fft.ifft(e0_q * transfer)


def fresnel_scale(z, wavelength):
    """Fresnel zone radius — the characteristic scale of the diffraction."""
    return np.sqrt(wavelength * z / (2.0 * np.pi))


def generate_event(
    duration_s=600.0,
    fs=50.0,
    rms_phase=1.0,
    p=DEFAULT_SPECTRAL_INDEX,
    screen_height=DEFAULT_SCREEN_HEIGHT,
    drift_velocity=DEFAULT_DRIFT_VELOCITY,
    wavelength=LAMBDA_L5,
    outer_scale=DEFAULT_OUTER_SCALE,
    rng=None,
):
    """
    Generate one scintillation event as a time series.

    Returns dict with:
        t      : time vector (s)
        I      : normalised intensity
        phase  : carrier phase (rad, unwrapped)
        meta   : parameters used
    """
    if rng is None:
        rng = np.random.default_rng()

    n = int(duration_s * fs)
    # round up to a power of two for a clean FFT
    n_fft = 1 << int(np.ceil(np.log2(n)))

    dt = 1.0 / fs
    dx = drift_velocity * dt          # spatial sampling from frozen-flow

    phi = make_phase_screen(n_fft, dx, p, rms_phase, rng, outer_scale)
    field = fresnel_propagate(phi, dx, screen_height, wavelength)

    field = field[:n]
    intensity = np.abs(field) ** 2
    intensity = intensity / np.mean(intensity)      # normalise <I> = 1
    phase = np.unwrap(np.angle(field))

    t = np.arange(n) * dt

    return {
        "t": t,
        "I": intensity,
        "phase": phase,
        "meta": {
            "duration_s": duration_s,
            "fs": fs,
            "rms_phase": rms_phase,
            "spectral_index": p,
            "screen_height_m": screen_height,
            "drift_velocity_ms": drift_velocity,
            "wavelength_m": wavelength,
            "outer_scale_m": outer_scale,
            "fresnel_scale_m": float(fresnel_scale(screen_height, wavelength)),
        },
    }


# --------------------------------------------------------------------------
# Index computation (reference implementation — see scint_indices.py for the
# streaming version that matches the SICU hardware)
# --------------------------------------------------------------------------
def compute_s4(intensity):
    """S4 = normalised standard deviation of intensity."""
    mi = np.mean(intensity)
    mi2 = np.mean(intensity ** 2)
    if mi <= 0:
        return 0.0
    val = (mi2 - mi ** 2) / (mi ** 2)
    return float(np.sqrt(max(val, 0.0)))


def compute_sigma_phi(phase, fs, cutoff_hz=0.1, order=6):
    """
    sigma_phi = standard deviation of detrended carrier phase.

    Conventional GNSS practice applies a high-pass detrending filter, commonly
    quoted around 0.1 Hz. TRACK A MUST CONFIRM the filter order and cutoff
    against a primary ISM receiver specification before this is used in the
    paper or baked into the RTL.
    """
    try:
        from scipy.signal import butter, filtfilt
    except ImportError:
        # Fallback: linear detrend only. Not equivalent — flag it.
        detrended = phase - np.polyval(
            np.polyfit(np.arange(len(phase)), phase, 1), np.arange(len(phase))
        )
        return float(np.std(detrended))

    nyq = fs / 2.0
    wn = cutoff_hz / nyq
    if not (0 < wn < 1):
        return float(np.std(phase))
    b, a = butter(order, wn, btype="highpass")
    return float(np.std(filtfilt(b, a, phase)))


# --------------------------------------------------------------------------
# Dataset builder
# --------------------------------------------------------------------------
# Class thresholds — VERIFY AND CITE (Track A / Track B).
# Conventional S4 bands are roughly: <0.2 none, 0.2-0.4 weak,
# 0.4-0.6 moderate, >0.6 strong. Conventions vary by author; pick one,
# cite it, and state it in the paper.
CLASS_THRESHOLDS = {"NOMINAL": 0.2, "DEGRADED": 0.5}


def classify(s4):
    if s4 < CLASS_THRESHOLDS["NOMINAL"]:
        return 0    # NOMINAL
    if s4 < CLASS_THRESHOLDS["DEGRADED"]:
        return 1    # DEGRADED
    return 2        # SEVERE


def build_dataset(
    n_events=200,
    window_s=10.0,
    seq_len=32,
    horizon_s=30.0,
    fs=50.0,
    seed=0,
    out_dir=".",
):
    """
    Build an LSTM training set.

    Each sample is:
        X : (seq_len, 2)  -- [S4, sigma_phi] over consecutive `window_s` windows
        y : class label at `horizon_s` into the future

    With window_s = 10 s and seq_len = 32 the model sees 320 s of history to
    predict 30 s ahead — a sensible ratio. At window_s = 1 s it would be
    32 s of noise predicting 30 s ahead, which is not.
    """
    rng = np.random.default_rng(seed)

    samples_X = []
    samples_y = []
    meta_rows = []

    # Sweep rms_phase to get a spread of severities. Deliberately oversample
    # the strong end: real scintillation is rare (a few percent of days), so a
    # naively sampled set would be ~99% NOMINAL and the model would learn to
    # predict NOMINAL forever and score 96% "accuracy".
    rms_choices = np.concatenate([
        rng.uniform(0.05, 0.35, n_events // 3),   # weak     -> S4 ~ 0.03-0.25
        rng.uniform(0.35, 0.9, n_events // 3),    # moderate -> S4 ~ 0.25-0.60
        rng.uniform(0.9, 3.0, n_events - 2 * (n_events // 3)),  # strong -> S4 > 0.6
    ])
    rng.shuffle(rms_choices)

    total_s = (seq_len * window_s) + horizon_s + window_s

    for ev_idx, rms in enumerate(rms_choices):
        ev = generate_event(
            duration_s=total_s,
            fs=fs,
            rms_phase=float(rms),
            p=float(rng.uniform(2.5, 3.5)),
            drift_velocity=float(rng.uniform(50.0, 200.0)),
            rng=rng,
        )

        n_win = int(window_s * fs)
        n_windows = len(ev["I"]) // n_win

        s4_series = []
        sphi_series = []
        for w in range(n_windows):
            sl = slice(w * n_win, (w + 1) * n_win)
            s4_series.append(compute_s4(ev["I"][sl]))
            sphi_series.append(compute_sigma_phi(ev["phase"][sl], fs))

        s4_series = np.array(s4_series)
        sphi_series = np.array(sphi_series)

        horizon_win = int(round(horizon_s / window_s))
        if len(s4_series) < seq_len + horizon_win:
            continue

        X = np.stack([
            s4_series[:seq_len],
            sphi_series[:seq_len],
        ], axis=1)
        y = classify(s4_series[seq_len + horizon_win - 1])

        samples_X.append(X)
        samples_y.append(y)
        meta_rows.append({
            "event": ev_idx,
            "rms_phase": float(rms),
            "s4_mean": float(np.mean(s4_series[:seq_len])),
            "label": int(y),
        })

    X = np.array(samples_X, dtype=np.float32)
    y = np.array(samples_y, dtype=np.int64)

    os.makedirs(out_dir, exist_ok=True)
    np.savez_compressed(
        os.path.join(out_dir, "scint_dataset.npz"),
        X=X, y=y,
    )
    with open(os.path.join(out_dir, "scint_dataset_meta.json"), "w") as f:
        json.dump({
            "n_samples": int(len(y)),
            "seq_len": seq_len,
            "window_s": window_s,
            "horizon_s": horizon_s,
            "fs": fs,
            "features": ["S4", "sigma_phi"],
            "classes": ["NOMINAL", "DEGRADED", "SEVERE"],
            "class_counts": {
                "NOMINAL": int(np.sum(y == 0)),
                "DEGRADED": int(np.sum(y == 1)),
                "SEVERE": int(np.sum(y == 2)),
            },
            "thresholds": CLASS_THRESHOLDS,
            "seed": seed,
            "rows": meta_rows,
        }, f, indent=2)

    return X, y


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def demo():
    rng = np.random.default_rng(42)
    print("NavIC L5 wavelength  : %.4f m" % LAMBDA_L5)
    print("Fresnel scale @350km : %.1f m"
          % fresnel_scale(DEFAULT_SCREEN_HEIGHT, LAMBDA_L5))
    print()
    print(" rms_phase     S4    sigma_phi   class")
    print(" ---------  ------  ----------  -------")
    names = ["NOMINAL", "DEGRADED", "SEVERE"]
    for rms in [0.1, 0.2, 0.35, 0.5, 1.0, 2.0, 4.0]:
        ev = generate_event(duration_s=300.0, fs=50.0,
                            rms_phase=rms, rng=rng)
        s4 = compute_s4(ev["I"])
        sphi = compute_sigma_phi(ev["phase"], 50.0)
        print("  %7.2f   %5.3f   %8.3f   %s"
              % (rms, s4, sphi, names[classify(s4)]))
    print()
    print("If S4 rises monotonically with rms_phase and saturates near 1,")
    print("the model is behaving as expected.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--demo", action="store_true",
                    help="print a sanity-check sweep")
    ap.add_argument("--dataset", action="store_true",
                    help="build an LSTM training set")
    ap.add_argument("--n-events", type=int, default=200)
    ap.add_argument("--window-s", type=float, default=10.0)
    ap.add_argument("--seq-len", type=int, default=32)
    ap.add_argument("--horizon-s", type=float, default=30.0)
    ap.add_argument("--fs", type=float, default=50.0)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default=".")
    args = ap.parse_args()

    if args.demo:
        demo()
    elif args.dataset:
        X, y = build_dataset(
            n_events=args.n_events,
            window_s=args.window_s,
            seq_len=args.seq_len,
            horizon_s=args.horizon_s,
            fs=args.fs,
            seed=args.seed,
            out_dir=args.out,
        )
        print("dataset: X%s  y%s" % (X.shape, y.shape))
        print("class counts: NOMINAL=%d DEGRADED=%d SEVERE=%d"
              % (np.sum(y == 0), np.sum(y == 1), np.sum(y == 2)))
        print("written to %s" % args.out)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
