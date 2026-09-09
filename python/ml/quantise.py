"""
Quantise a trained ScintLSTM to fixed point and choose a gate implementation.

The first run of this script showed that bit width is not the constraint --
Q10.6 through Q4.12 all scored identically -- but that a crude one-segment
piecewise-linear gate cost 0.173 F1 on its own. So this version sweeps the
NONLINEARITY implementation as well as the word format:

  exact       reference, np.exp / np.tanh, not implementable cheaply
  lut<N>      N-entry lookup table over a clipped input range, values in
              the same fixed point format as everything else. 256 entries
              in Q8.8 is 512 bytes of ROM per function.
  pwl<N>      N-segment piecewise linear, slopes chosen as powers of two
              where possible so hardware needs shifts rather than multiplies
  pwl1        the crude single-segment version, kept for comparison

The output tells you how many LUT entries or PWL segments the accelerator
actually needs, which is an RTL decision that has to be made before the
block is written.

Usage:
    python3 python/ml/quantise.py \
        --model sim/lstm_global3/lstm_h16_l2.pt \
        --data sim/vectors_cosmic2_global/cosmic2_dataset.npz \
        --bar 0.523
"""
import argparse
import json
import os

import numpy as np
import torch

CLASS_NAMES = ["NOMINAL", "DEGRADED", "SEVERE"]
SEVERE = 2


def event_split(event_ids, test_frac=0.2, val_frac=0.2, seed=0):
    """Must match lstm_train.py exactly or the test split differs."""
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
    return out


def quantise(x, frac_bits, width=16, signed=True):
    if frac_bits is None:
        return np.asarray(x, dtype=np.float64)
    scale = float(1 << frac_bits)
    lo = -(1 << (width - 1)) if signed else 0
    hi = (1 << (width - 1)) - 1 if signed else (1 << width) - 1
    # Round-half-up, matching lstm_accel.sv's sat_round:
    #   r = (a + (1 << (FRAC-1))) >>> FRAC
    # numpy's rint is round-half-to-EVEN, which drifts against the RTL by
    # up to half an LSB per operation and accumulates over 32 timesteps.
    # The hardware convention is the reference, so numpy follows it.
    q = np.floor(np.asarray(x, dtype=np.float64) * scale + 0.5)
    return (np.clip(q, lo, hi) / scale).astype(np.float64)


# ----------------------------------------------------------------------
# Gate implementations
# ----------------------------------------------------------------------

def _sig(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -60.0, 60.0)))


class Gates:
    """
    Provides sigmoid() and tanh() under a chosen hardware scheme.

      kind='exact'   reference
      kind='lut'     n_entries over [-x_range, +x_range], nearest-entry
      kind='pwl'     n_seg segments, least-squares fit per segment
      kind='pwl1'    the crude single-segment version
    """

    def __init__(self, kind="exact", n=256, x_range=8.0, frac_bits=None):
        self.kind = kind
        self.n = n
        self.x_range = x_range
        self.fb = frac_bits
        if kind == "lut":
            self.grid = np.linspace(-x_range, x_range, n)
            self.sig_tab = quantise(_sig(self.grid), frac_bits)
            self.tanh_tab = quantise(np.tanh(self.grid), frac_bits)
        elif kind == "pwl":
            self.sig_seg = self._fit(_sig, n, x_range)
            self.tanh_seg = self._fit(np.tanh, n, x_range)

    def _fit(self, fn, n_seg, x_range):
        """Least-squares line per segment; returns (edges, slopes, offsets)."""
        edges = np.linspace(-x_range, x_range, n_seg + 1)
        slopes, offsets = [], []
        for a, b in zip(edges[:-1], edges[1:]):
            xs = np.linspace(a, b, 64)
            ys = fn(xs)
            m, c = np.polyfit(xs, ys, 1)
            slopes.append(quantise(m, self.fb).item() if self.fb else m)
            offsets.append(quantise(c, self.fb).item() if self.fb else c)
        return edges, np.array(slopes), np.array(offsets)

    def _lut(self, x, table):
        idx = np.rint((np.clip(x, -self.x_range, self.x_range) + self.x_range)
                      / (2 * self.x_range) * (self.n - 1)).astype(np.int64)
        return table[idx]

    def _pwl(self, x, seg, lo, hi):
        edges, slopes, offsets = seg
        xc = np.clip(x, edges[0], edges[-1])
        idx = np.clip(np.searchsorted(edges, xc, side="right") - 1,
                      0, len(slopes) - 1)
        return np.clip(slopes[idx] * xc + offsets[idx], lo, hi)

    def sigmoid(self, x):
        if self.kind == "exact":
            return _sig(x)
        if self.kind == "lut":
            return self._lut(x, self.sig_tab)
        if self.kind == "pwl":
            return self._pwl(x, self.sig_seg, 0.0, 1.0)
        return np.clip(0.25 * x + 0.5, 0.0, 1.0)      # pwl1

    def tanh(self, x):
        if self.kind == "exact":
            return np.tanh(x)
        if self.kind == "lut":
            return self._lut(x, self.tanh_tab)
        if self.kind == "pwl":
            return self._pwl(x, self.tanh_seg, -1.0, 1.0)
        return np.clip(x, -1.0, 1.0)                  # pwl1

    def max_abs_error(self):
        xs = np.linspace(-8, 8, 4001)
        es = np.max(np.abs(self.sigmoid(xs) - _sig(xs)))
        et = np.max(np.abs(self.tanh(xs) - np.tanh(xs)))
        return max(es, et)


class QuantLSTM:
    """numpy LSTM + Linear head with quantisation at every step."""

    def __init__(self, state, hidden, layers, gates, frac_bits=None,
                 acc_frac_bits=None):
        self.hidden = hidden
        self.layers = layers
        self.g = gates
        self.fb = frac_bits
        self.afb = acc_frac_bits if acc_frac_bits is not None else frac_bits
        self.w = {k: quantise(v.detach().cpu().numpy(), frac_bits)
                  for k, v in state.items()}

    def _cell(self, x, h, c, layer):
        wi = self.w["lstm.weight_ih_l%d" % layer]
        wh = self.w["lstm.weight_hh_l%d" % layer]
        b = self.w["lstm.bias_ih_l%d" % layer] + self.w["lstm.bias_hh_l%d" % layer]
        z = quantise(x @ wi.T + h @ wh.T + b, self.afb)
        H = self.hidden
        i = quantise(self.g.sigmoid(z[:, 0:H]), self.fb)
        f = quantise(self.g.sigmoid(z[:, H:2 * H]), self.fb)
        g = quantise(self.g.tanh(z[:, 2 * H:3 * H]), self.fb)
        o = quantise(self.g.sigmoid(z[:, 3 * H:4 * H]), self.fb)
        c = quantise(f * c + i * g, self.afb)
        h = quantise(o * self.g.tanh(c), self.fb)
        return h, c

    def forward(self, x):
        n, t, _ = x.shape
        h = [np.zeros((n, self.hidden)) for _ in range(self.layers)]
        c = [np.zeros((n, self.hidden)) for _ in range(self.layers)]
        for step in range(t):
            inp = quantise(x[:, step, :], self.fb)
            for l in range(self.layers):
                h[l], c[l] = self._cell(inp, h[l], c[l], l)
                inp = h[l]
        return quantise(h[-1] @ self.w["head.weight"].T + self.w["head.bias"],
                        self.afb)


def softmax(z):
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def apply_threshold(prob, thr):
    pred = np.argmax(prob[:, :2], axis=1)
    pred[prob[:, 2] >= thr] = 2
    return pred


def evaluate(model, x, y, thr, batch=8192):
    preds = []
    for s in range(0, len(x), batch):
        preds.append(apply_threshold(softmax(model.forward(x[s:s + batch])), thr))
    return metrics(y, np.concatenate(preds))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default="sim/quant/")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--bar", type=float, default=None)
    ap.add_argument("--limit", type=int, default=200000)
    ap.add_argument("--frac-bits", type=int, default=8,
                    help="fixed point format for the gate comparison")
    args = ap.parse_args()

    ck = torch.load(args.model, map_location="cpu", weights_only=False)
    hidden, layers = ck["hidden"], ck["layers"]
    thr = ck.get("threshold", 0.5)
    mu = np.array(ck["norm"]["mu"], dtype=np.float64)
    sd = np.array(ck["norm"]["sd"], dtype=np.float64)
    print("model: hidden=%d layers=%d threshold=%.2f" % (hidden, layers, thr))

    d = np.load(args.data)
    x, y = d["X"], d["y"]
    ev = d["event_ids"] if "event_ids" in d else np.arange(len(y))
    _, _, te = event_split(ev, seed=args.seed)
    xt = (x[te].astype(np.float64) - mu) / sd
    yt = y[te]
    if args.limit and len(yt) > args.limit:
        rng = np.random.default_rng(args.seed)
        keep = rng.choice(len(yt), size=args.limit, replace=False)
        xt, yt = xt[keep], yt[keep]
    print("test samples: %d (SEVERE = %d)\n"
          % (len(yt), int(np.sum(yt == SEVERE))))

    rows = []
    fb = args.frac_bits

    print("=" * 74)
    print("GATE IMPLEMENTATION SWEEP  (weights and activations in Q%d.%d)"
          % (16 - fb, fb))
    print("=" * 74)
    print("  gate          cost           max|err|   SEV prec  SEV rec  SEV F1")

    configs = [
        ("exact (float ref)", dict(kind="exact"), None, "-"),
        ("lut 512",           dict(kind="lut", n=512), fb, "1 KB ROM"),
        ("lut 256",           dict(kind="lut", n=256), fb, "512 B ROM"),
        ("lut 128",           dict(kind="lut", n=128), fb, "256 B ROM"),
        ("lut 64",            dict(kind="lut", n=64),  fb, "128 B ROM"),
        ("lut 32",            dict(kind="lut", n=32),  fb, "64 B ROM"),
        ("pwl 8 seg",         dict(kind="pwl", n=8),   fb, "8 mul+add"),
        ("pwl 4 seg",         dict(kind="pwl", n=4),   fb, "4 mul+add"),
        ("pwl 2 seg",         dict(kind="pwl", n=2),   fb, "2 mul+add"),
        ("pwl 1 seg (crude)", dict(kind="pwl1"),       fb, "1 clamp"),
    ]

    base_f1 = None
    for label, kw, gfb, cost in configs:
        gates = Gates(frac_bits=gfb, **kw)
        use_fb = None if kw["kind"] == "exact" else fb
        model = QuantLSTM(ck["state_dict"], hidden, layers, gates,
                          frac_bits=use_fb)
        m = evaluate(model, xt, yt, thr)
        dd = m[SEVERE]
        if base_f1 is None:
            base_f1 = dd["f1"]
        err = gates.max_abs_error() if kw["kind"] != "exact" else 0.0
        print("  %-18s %-13s %8.4f  %8.3f %8.3f %7.3f"
              % (label, cost, err, dd["precision"], dd["recall"], dd["f1"]))
        rows.append(dict(gate=label, cost=cost, max_err=float(err),
                         precision=dd["precision"], recall=dd["recall"],
                         f1=dd["f1"], delta=dd["f1"] - base_f1))
    print("=" * 74)

    fixed = [r for r in rows if r["gate"] != "exact (float ref)"]
    best = max(fixed, key=lambda r: r["f1"])
    print("\nbest hardware-implementable gate: %s -> SEVERE F1 %.3f (%+.3f vs exact)"
          % (best["gate"], best["f1"], best["delta"]))
    if args.bar is not None:
        delta = best["f1"] - args.bar
        print("  baseline bar = %.3f -> %s it by %+.3f"
              % (args.bar, "BEATS" if delta > 0 else "does NOT beat", delta))
    cheap = [r for r in fixed if r["delta"] > -0.01]
    if cheap:
        c = min(cheap, key=lambda r: r["max_err"] if r["max_err"] else 1e9)
        print("  cheapest option within 0.01 of exact: %s (%s)"
              % (c["gate"], c["cost"]))

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "gate_results.json"), "w") as f:
        json.dump(dict(model=args.model, frac_bits=fb, threshold=thr,
                       samples=int(len(yt)), bar=args.bar, rows=rows),
                  f, indent=2)
    print("\nwritten to %s" % args.out)


if __name__ == "__main__":
    main()
