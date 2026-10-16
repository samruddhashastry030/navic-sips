"""
Firmware tunables stored in the weight image, so they can change after
tape-out with the weights instead of being frozen in the boot ROM.

The block sits in the image's padding, after the 992 slots the h8_l2 model
uses (rtl/weights/WEIGHT_FORMAT.md). fw/main.c read_config() reads it; an
image without the tag runs on the firmware's built-in defaults, which are
the DEFAULT_* values here.

  slot 992  tag 0xC0F1
  slot 993  version 1
  slot 994  SEVERE margin, Q8.8 signed: SEVERE when
            logit2 - max(logit0, logit1) >= margin (derive_margin.py)
  slot 995  confidence shift, 0..15: conf = margin_to_runner_up >> shift
  slot 996  loop settings for NOMINAL   } packed as fw/sips.h LOOP():
  slot 997  loop settings for DEGRADED  } [2:0] PLL bandwidth code,
  slot 998  loop settings for SEVERE    } [3] FLL, [6:4] T_coh code, [8:7] band

The whole image, block included, is covered by the flash checksum and the
firmware's SRAM scrub.

Patch an existing export without retraining:
    python3 python/ml/config_block.py rtl/weights/              # defaults
    python3 python/ml/config_block.py rtl/weights/ --margin 0.30 --conf-shift 5
    python3 python/ml/config_block.py rtl/weights/ --loop 0x020,0x021,0x01b
"""
import argparse
import os

CFG_SLOT = 992
CFG_TAG = 0xC0F1
CFG_VERSION = 1
CFG_SLOTS = 7

DEFAULT_MARGIN = 0.25                  # derive_margin.py, shipping L1-only model
DEFAULT_CONF_SHIFT = 6                 # one confidence step per 0.25 of margin
DEFAULT_LOOP = (0x020, 0x021, 0x01B)   # LOOP(0,0,2,0) LOOP(1,0,2,0) LOOP(3,1,1,0)


def config_slots(margin=DEFAULT_MARGIN, conf_shift=DEFAULT_CONF_SHIFT,
                 loop=DEFAULT_LOOP):
    """The block as seven 16-bit slot values (unsigned)."""
    m = int(round(margin * 256))
    if not -32768 <= m <= 32767:
        raise ValueError("margin %.4f does not fit Q8.8" % margin)
    if not 0 <= conf_shift <= 15:
        raise ValueError("conf_shift must be 0..15")
    if len(loop) != 3 or any(not 0 <= c < 0x200 for c in loop):
        raise ValueError("loop needs three 9-bit codes")
    return [CFG_TAG, CFG_VERSION, m & 0xFFFF, conf_shift] + list(loop)


def apply(slots, **kw):
    """Write the block into a list/array of 1024 slots (in place)."""
    if len(slots) < CFG_SLOT + CFG_SLOTS:
        raise ValueError("image too short for the config block")
    if any(int(s) != 0 for s in slots[CFG_SLOT:CFG_SLOT + CFG_SLOTS]) \
            and int(slots[CFG_SLOT]) & 0xFFFF != CFG_TAG:
        raise ValueError("slots %d-%d are not padding: the model has grown "
                         "into the config block" % (CFG_SLOT, CFG_SLOT + CFG_SLOTS - 1))
    for i, v in enumerate(config_slots(**kw)):
        slots[CFG_SLOT + i] = v
    return slots


def _patch(out_dir, **kw):
    hex_path = os.path.join(out_dir, "weights.hex")
    words = [int(l, 16) for l in open(hex_path).read().split()]
    slots = []
    for w in words:
        slots += [w & 0xFFFF, w >> 16]
    apply(slots, **kw)
    words = [(slots[i] & 0xFFFF) | ((slots[i + 1] & 0xFFFF) << 16)
             for i in range(0, len(slots), 2)]
    with open(hex_path, "w") as f:
        f.write("".join("%08X\n" % w for w in words))
    with open(os.path.join(out_dir, "weights.bin"), "wb") as f:
        f.write(b"".join(w.to_bytes(4, "little") for w in words))
    return config_slots(**kw)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out_dir", help="directory holding weights.hex / weights.bin")
    ap.add_argument("--margin", type=float, default=DEFAULT_MARGIN)
    ap.add_argument("--conf-shift", type=int, default=DEFAULT_CONF_SHIFT)
    ap.add_argument("--loop", default=",".join("0x%03x" % c for c in DEFAULT_LOOP),
                    help="three codes, NOMINAL,DEGRADED,SEVERE")
    a = ap.parse_args()
    loop = tuple(int(c, 0) for c in a.loop.split(","))
    vals = _patch(a.out_dir, margin=a.margin, conf_shift=a.conf_shift, loop=loop)
    print("config block at slots %d-%d: %s" % (CFG_SLOT, CFG_SLOT + CFG_SLOTS - 1,
                                                " ".join("%04x" % v for v in vals)))


if __name__ == "__main__":
    main()
