"""
Export a trained ScintLSTM to the artefacts the silicon needs:

  weights.hex        512 lines of 32-bit hex, one SRAM word each, for
                     $readmemh or for the SPI flash image
  weights.bin        the same bytes, for programming external flash
  lut_sigmoid.hex    256 lines of 16-bit hex, Q8.8 sigmoid table
  lut_tanh.hex       256 lines of 16-bit hex, Q8.8 tanh table
  golden_vectors.hex input/expected pairs for RTL verification
  WEIGHT_FORMAT.md   the layout spec, so the RTL and this script cannot
                     silently disagree

Everything is Q8.8: signed 16-bit, 8 fractional bits, two's complement.
Two weights per 32-bit SRAM word, even index in the low half.

The weight SRAM is 512 x 32 = 1024 slots. h8_l2 uses 987 + 5 header
slots and fits; h16_l2 needs 3507 and does not. The script refuses to
write an image that would not fit rather than truncating silently.

Usage:
    python3 python/ml/export_weights.py \
        --model sim/lstm_sweep/lstm_h8_l2.pt \
        --data sim/vectors_cosmic2_global/cosmic2_dataset.npz \
        --out rtl/weights/
"""
import argparse
import json
import os

import numpy as np
import torch

FRAC_BITS = 8
WORD_BITS = 16
SRAM_WORDS = 512          # 32-bit words
SRAM_SLOTS = SRAM_WORDS * 2   # 16-bit weight slots
LUT_ENTRIES = 256
LUT_RANGE = 8.0

# Order is fixed. The RTL must walk the weights in exactly this sequence.
WEIGHT_ORDER = [
    "lstm.weight_ih_l0", "lstm.weight_hh_l0",
    "lstm.bias_ih_l0", "lstm.bias_hh_l0",
    "lstm.weight_ih_l1", "lstm.weight_hh_l1",
    "lstm.bias_ih_l1", "lstm.bias_hh_l1",
    "head.weight", "head.bias",
]


def to_q88(x):
    """float -> signed 16-bit Q8.8, saturating."""
    q = np.rint(np.asarray(x, dtype=np.float64) * (1 << FRAC_BITS))
    return np.clip(q, -32768, 32767).astype(np.int32)


def from_q88(q):
    return q.astype(np.float64) / (1 << FRAC_BITS)


def u16(v):
    """signed int -> unsigned 16-bit pattern"""
    return int(v) & 0xFFFF


def flatten_weights(state, layers):
    """Return (values, manifest). Row-major within each tensor."""
    vals, manifest, idx = [], [], 0
    for name in WEIGHT_ORDER:
        if name not in state:
            if name.endswith("_l1") and layers < 2:
                continue
            raise KeyError("checkpoint is missing %s" % name)
        arr = state[name].detach().cpu().numpy().astype(np.float64)
        flat = arr.reshape(-1)
        manifest.append(dict(name=name, shape=list(arr.shape),
                             start=idx, count=int(flat.size)))
        vals.append(flat)
        idx += flat.size
    return np.concatenate(vals), manifest


def build_luts():
    grid = np.linspace(-LUT_RANGE, LUT_RANGE, LUT_ENTRIES)
    sig = 1.0 / (1.0 + np.exp(-grid))
    tanh = np.tanh(grid)
    return to_q88(sig), to_q88(tanh), grid


def write_hex16(path, values):
    with open(path, "w") as f:
        for v in values:
            f.write("%04X\n" % u16(v))


def write_words32(path_hex, path_bin, slots):
    """Pack 16-bit slots two per 32-bit word, even index in the low half."""
    words = []
    for i in range(0, len(slots), 2):
        lo = u16(slots[i])
        hi = u16(slots[i + 1]) if i + 1 < len(slots) else 0
        words.append((hi << 16) | lo)
    with open(path_hex, "w") as f:
        for w in words:
            f.write("%08X\n" % w)
    with open(path_bin, "wb") as f:
        for w in words:
            f.write(w.to_bytes(4, "little"))
    return words


def golden_vectors(ck, data_path, n, seed, out_dir, hidden, layers):
    """Quantised forward pass over n real samples, saved as RTL stimulus."""
    from importlib.machinery import SourceFileLoader
    here = os.path.dirname(os.path.abspath(__file__))
    q = SourceFileLoader("quantise",
                         os.path.join(here, "quantise.py")).load_module()

    d = np.load(data_path)
    x, y = d["X"], d["y"]
    ev = d["event_ids"] if "event_ids" in d else np.arange(len(y))
    _, _, te = q.event_split(ev, seed=seed)
    xi = np.flatnonzero(te)

    rng = np.random.default_rng(seed)
    # Keep the class mix interesting: half SEVERE, half everything else.
    sev = xi[y[xi] == 2]
    oth = xi[y[xi] != 2]
    take_s = min(n // 2, len(sev))
    pick = np.concatenate([rng.choice(sev, take_s, replace=False),
                           rng.choice(oth, n - take_s, replace=False)])
    rng.shuffle(pick)

    mu = np.array(ck["norm"]["mu"], dtype=np.float64)
    sd = np.array(ck["norm"]["sd"], dtype=np.float64)
    xs = (x[pick].astype(np.float64) - mu) / sd

    gates = q.Gates(kind="lut", n=LUT_ENTRIES, x_range=LUT_RANGE,
                    frac_bits=FRAC_BITS)
    model = q.QuantLSTM(ck["state_dict"], hidden, layers, gates,
                        frac_bits=FRAC_BITS)
    logits = model.forward(xs)
    pred = np.argmax(logits, axis=1)

    path = os.path.join(out_dir, "golden_vectors.hex")
    with open(path, "w") as f:
        f.write("// %d vectors. Each: 32 timesteps x 2 features in Q8.8,\n"
                "// then 3 logits in Q8.8, then the argmax class.\n"
                "// Inputs are ALREADY normalised: (raw - mu) / sd.\n"
                % len(pick))
        for k in range(len(pick)):
            seq = to_q88(xs[k])
            f.write("// vector %d  true_class=%d\n" % (k, int(y[pick[k]])))
            for t in range(seq.shape[0]):
                f.write("%04X %04X\n" % (u16(seq[t, 0]), u16(seq[t, 1])))
            lg = to_q88(logits[k])
            f.write("EXP %04X %04X %04X %d\n"
                    % (u16(lg[0]), u16(lg[1]), u16(lg[2]), int(pred[k])))
    agree = float(np.mean(pred == y[pick]))
    return path, len(pick), agree


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", default=None,
                    help="dataset for golden vectors; omit to skip them")
    ap.add_argument("--out", default="rtl/weights/")
    ap.add_argument("--vectors", type=int, default=64)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--allow-oversize", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    ck = torch.load(args.model, map_location="cpu", weights_only=False)
    hidden, layers = ck["hidden"], ck["layers"]
    thr = ck.get("threshold", 0.5)
    mu = np.array(ck["norm"]["mu"], dtype=np.float64)
    sd = np.array(ck["norm"]["sd"], dtype=np.float64)

    vals, manifest = flatten_weights(ck["state_dict"], layers)
    n_w = len(vals)

    # Header: mu[2], 1/sd[2], threshold -> 5 slots, then the weights.
    # The RECIPROCAL of sd is stored, not sd itself, so the firmware
    # normalises with a multiply rather than a divide. PicoRV32 has no
    # divider, and a software divide once per feature per 10 s window is
    # avoidable work.
    inv_sd = 1.0 / sd
    header = np.concatenate([mu, inv_sd, [thr]])
    slots = np.concatenate([to_q88(header), to_q88(vals)])
    used = len(slots)

    print("model:   %s (hidden=%d layers=%d)"
          % (os.path.basename(args.model), hidden, layers))
    print("weights: %d   header: %d   total slots: %d of %d"
          % (n_w, len(header), used, SRAM_SLOTS))

    if used > SRAM_SLOTS:
        print("\n  DOES NOT FIT. The weight SRAM holds %d 16-bit slots and "
              "this model needs %d." % (SRAM_SLOTS, used))
        print("  Options: use a smaller model (h8_l2 = 987 weights fits), "
              "enlarge the SRAM, or stream per layer.")
        if not args.allow_oversize:
            raise SystemExit(1)
        print("  --allow-oversize given: writing anyway, image will be "
              "larger than one SRAM.")
    else:
        print("fits with %d slots spare (%.1f%% used)"
              % (SRAM_SLOTS - used, 100.0 * used / SRAM_SLOTS))

    pad = max(0, SRAM_SLOTS - used)
    slots = np.concatenate([slots, np.zeros(pad, dtype=np.int32)])

    words = write_words32(os.path.join(args.out, "weights.hex"),
                          os.path.join(args.out, "weights.bin"), slots)
    print("\nwrote weights.hex / weights.bin (%d words, %d bytes)"
          % (len(words), 4 * len(words)))

    sig, tanh, grid = build_luts()
    write_hex16(os.path.join(args.out, "lut_sigmoid.hex"), sig)
    write_hex16(os.path.join(args.out, "lut_tanh.hex"), tanh)
    print("wrote lut_sigmoid.hex / lut_tanh.hex (%d entries each, %d B ROM total)"
          % (LUT_ENTRIES, 2 * LUT_ENTRIES * 2))

    # Round-trip check: does the Q8.8 image reconstruct the float weights?
    err = np.max(np.abs(from_q88(to_q88(vals)) - vals))
    print("max weight quantisation error: %.6f  (Q8.8 LSB = %.6f)"
          % (err, 1.0 / (1 << FRAC_BITS)))
    sat = int(np.sum(np.abs(vals) >= 128.0))
    if sat:
        print("  WARNING: %d weights saturate the Q8.8 integer range" % sat)

    with open(os.path.join(args.out, "weight_manifest.json"), "w") as f:
        json.dump(dict(model=args.model, hidden=hidden, layers=layers,
                       frac_bits=FRAC_BITS, threshold=thr,
                       mu=mu.tolist(), sd=sd.tolist(), inv_sd=(1.0/sd).tolist(),
                       header_slots=len(header), weight_slots=int(n_w),
                       total_slots=int(used), sram_slots=SRAM_SLOTS,
                       lut_entries=LUT_ENTRIES, lut_range=LUT_RANGE,
                       tensors=manifest), f, indent=2)

    spec = os.path.join(args.out, "WEIGHT_FORMAT.md")
    with open(spec, "w") as f:
        f.write("# Weight image format\n\n")
        f.write("Generated by python/ml/export_weights.py from `%s`.\n"
                "The RTL must match this exactly.\n\n" % args.model)
        f.write("## Numeric format\n\n")
        f.write("Signed 16-bit two's complement, Q%d.%d (%d fractional bits, "
                "LSB = %.6f).\n" % (WORD_BITS - FRAC_BITS, FRAC_BITS,
                                    FRAC_BITS, 1.0 / (1 << FRAC_BITS)))
        f.write("Two values per 32-bit SRAM word: even slot index in bits "
                "[15:0], odd in bits [31:16].\n\n")
        f.write("## SRAM map (512 x 32 = %d slots)\n\n" % SRAM_SLOTS)
        f.write("| slot | contents |\n|---|---|\n")
        f.write("| 0-1 | normalisation mean, feature 0 and 1 |\n")
        f.write("| 2-3 | RECIPROCAL of normalisation std dev, feature 0 and 1 |\n")
        f.write("| 4 | SEVERE decision threshold |\n")
        for m in manifest:
            f.write("| %d-%d | %s %s |\n"
                    % (5 + m["start"], 5 + m["start"] + m["count"] - 1,
                       m["name"], "x".join(str(s) for s in m["shape"])))
        f.write("| %d-%d | zero padding |\n\n" % (used, SRAM_SLOTS - 1))
        f.write("Tensors are flattened row-major. LSTM gate order inside the "
                "4H rows is PyTorch's: input, forget, cell, output.\n\n")
        f.write("## Gate LUTs\n\n")
        f.write("`lut_sigmoid.hex` and `lut_tanh.hex` hold %d Q8.8 entries "
                "each, covering input range [-%.1f, +%.1f] uniformly.\n"
                % (LUT_ENTRIES, LUT_RANGE, LUT_RANGE))
        f.write("Index = round((clip(x, -%.1f, %.1f) + %.1f) / %.1f * %d).\n"
                % (LUT_RANGE, LUT_RANGE, LUT_RANGE, 2 * LUT_RANGE,
                   LUT_ENTRIES - 1))
        f.write("These live in ROM, not the weight SRAM.\n\n")
        f.write("## Inference\n\n")
        f.write("Input is `(raw_S4 - mu) / sd` per feature, %d timesteps, "
                "2 features. Run %d LSTM layers of %d hidden units, take the "
                "final hidden state, apply the head, then predict SEVERE if "
                "P(SEVERE) >= threshold else argmax of the other two.\n"
                % (32, layers, hidden))
    print("wrote WEIGHT_FORMAT.md and weight_manifest.json")

    if args.data:
        path, n, agree = golden_vectors(ck, args.data, args.vectors,
                                        args.seed, args.out, hidden, layers)
        print("wrote %s (%d vectors, quantised model agrees with labels "
              "on %.1f%% of them)" % (os.path.basename(path), n, 100 * agree))

    print("\noutput directory: %s" % args.out)


if __name__ == "__main__":
    main()
