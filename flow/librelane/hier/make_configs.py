"""Hierarchical (macro-based) layout of NavIC-SIPS.

Run from the repo root:   python3 flow/librelane/hier/make_configs.py

Instead of one flat pool of ~60,000 cells, the three big blocks are each
hardened on their own as a rectangular macro, then placed on the chip like
tiles next to the two SRAMs. The flat build (flow/librelane/navic_sips_top)
is left untouched as the fallback.

    stage 1  harden the macros (each ~10-20 min):
               cpu_core   PicoRV32 RV32IMC          rtl/cpu_core.sv
               acc_core   LSTM accelerator          rtl/acc_core.sv
               sicu       scintillation index unit  rtl/sicu.sv
    stage 2  re-run this script: it finds each macro's finished run and writes
             flow/librelane/hier/navic_sips_top/config.json with all five
             macros placed, then harden the chip top (~1 h).

What makes a block a macro rather than a standalone design:
  - a fixed rectangle (FP_SIZING absolute), sized for ~45-50% utilisation
  - PDN_MULTILAYER false: its power grid stops at met4, so the chip's met5
    straps can run across it and connect down (PDN_MACRO_CONNECTIONS)
  - RT_MAX_LAYER met4: its signal routing stays below met5 too
  - pins on the side that faces the logic it talks to (pins.cfg), instead of
    scattered round all four edges
  - I/O timing budget: 8 ns of each 33 ns cycle is reserved for the wires
    and glue logic outside the macro, on inputs and on outputs. The chip-level
    STA, run on the real macro timing models, is the actual signoff.

Floorplan (die 2000 x 1200 um, origin bottom-left):

    y=1160 +-------------------+  +---------------+     +-------------+
           |     cpu_core      |  |   acc_core    |     |    sicu     | <- I/Q
           |     640 x 560     |  |   520 x 420   |     |  460 x 400  |   pins
           |                   |  +-----pins------+     +----pins-----+   on top
     y=600 +-------pins--------+          |                   |
                   |               glue logic (bus, ROM,      |
           +------------------+    regs, SPI, UART)    +-------------+
           |  u_weight_sram   |                        | u_event_sram|
           |  2 KB 683 x 417  |                        | 1 KB 480x398|
      y=40 +------------------+                        +-------------+
           x=40                                        x=1480
"""
import glob
import json
import os
import sys

ROOT = os.getcwd()
HIER = os.path.join(ROOT, "flow", "librelane", "hier")
if not os.path.exists(os.path.join(ROOT, "rtl", "navic_sips_top.sv")):
    sys.exit("run from the repo root")

RTL = "dir::../../../../rtl/"
for f in ("fw/firmware.hex", "rtl/weights/lut_sigmoid.hex", "rtl/weights/lut_tanh.hex"):
    if not os.path.exists(os.path.join(ROOT, f)):
        sys.exit("missing " + f + " -- build it first (make -C fw)")

CLOCK_NS = 33          # signoff
PNR_NS = 27            # implementation target (same over-constraint as flat)
IO_BUDGET_NS = 8       # reserved outside each macro, per input and output
PIN_INPUT_NS = 2.0     # inputs fed straight from chip pins (matches the chip SDC)
DIE_W, DIE_H = 2000, 1200

# Settings that took the flat chip to clean signoff; reused for every block.
COMMON = {
    "PDK": "sky130A",
    "CLOCK_PORT": "clk_i",
    "CLOCK_PERIOD": CLOCK_NS,
    "PNR_SDC_FILE": "dir::pnr.sdc",
    "SIGNOFF_SDC_FILE": "dir::base.sdc",
    "DESIGN_REPAIR_MAX_SLEW_PCT": 60,
    "DESIGN_REPAIR_MAX_CAP_PCT": 60,
    "RUN_POST_GRT_DESIGN_REPAIR": True,
    "GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 60,
    "GRT_DESIGN_REPAIR_MAX_CAP_PCT": 60,
    "RUN_HEURISTIC_DIODE_INSERTION": True,
    "DRT_ANTENNA_REPAIR_ITERS": 10,
}

# ---------------------------------------------------------------------------
# Macros. Sized from the standalone hardening runs so each block's cells
# (after timing repair) fill ~45-50% of it -- e.g. PicoRV32 ended at ~173,000
# um2 of cells standalone, so 640 x 560. A first guess: if a block reports a
# utilisation/density error or heavy congestion, grow its size by ~10% and
# re-run just that block (and move its location if it now overlaps).
# ---------------------------------------------------------------------------
MACROS = {
    "cpu_core": {
        "files": ["cpu_core.sv", "third_party/picorv32.v"],
        "size": (640, 560),
        "params": [],
        # every pin on the south edge, facing the glue logic below
        "pins": """#S
clk_i
rst_ni
mem_valid_o
mem_ready_i
mem_wstrb_o.*
mem_addr_o.*
mem_wdata_o.*
mem_rdata_i.*
""",
        "instance": "u_cpu",
        "location": (40.48, 598.4),    # on routing grid: x = n*0.92, y = n*13.6
    },
    "acc_core": {
        "files": ["acc_core.sv", "lstm_accel.sv"],
        "defines": ["SKY130_ICG"],     # use the PDK clock-gating cell (acc_core.sv)
        "size": (520, 420),
        "params": [
            'LUT_SIG="%s"' % os.path.join(ROOT, "rtl", "weights", "lut_sigmoid.hex"),
            'LUT_TANH="%s"' % os.path.join(ROOT, "rtl", "weights", "lut_tanh.hex"),
        ],
        # south edge: bus side, plus the weight-SRAM read port
        "pins": """#S
clk_i
rst_ni
start_i
busy_o
in_valid_i
in_ready_o
in_feat0_i.*
in_feat1_i.*
out_valid_o
class_o.*
logit0_o.*
logit1_o.*
logit2_o.*
w_csb_o
w_addr_o.*
w_dout_i.*
""",
        "instance": "u_acc",
        "location": (740.6, 734.4),    # on routing grid
    },
    "sicu": {
        "files": ["sicu.sv"],
        "size": (460, 400),
        "params": [],
        # I/Q samples arrive from the chip's top edge; results go down to the bus
        "pins": """#N
in_valid_i
i_i.*
q_i.*

#S
clk_i
rst_ni
enable_i
busy_o
in_ready_o
s4_valid_o
s4_o.*
saturated_o
shift_o.*
""",
        "instance": "u_sicu",
        "location": (1499.6, 748.0),   # on routing grid
        # I/Q come straight from chip pins and feed I^2+Q^2 -> shift -> accumulate
        # in one cycle: give them the chip SDC's 2 ns, not the 8 ns macro budget.
        "pin_inputs": ["in_valid_i", "i_i[*]", "q_i[*]"],
    },
}

SDC = """create_clock -name clk_i -period {period} [get_ports clk_i]
set_clock_uncertainty 0.25 [get_clocks clk_i]
set_clock_transition 0.15 [get_clocks clk_i]

# OpenSTA has no remove_from_collection; filter the port list in Tcl.
set inputs_no_clk {{}}
foreach p [all_inputs] {{
    if {{[get_property $p full_name] ne "clk_i"}} {{
        lappend inputs_no_clk $p
    }}
}}

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y $inputs_no_clk
set_load 0.02 [all_outputs]

# Macro I/O budget: {io} ns of the cycle belongs to the wires and glue logic
# outside this block. The chip-level STA on the real timing models is the
# actual signoff; this only keeps the block from spending that time itself.
set_input_delay  -clock clk_i {io} $inputs_no_clk
set_output_delay -clock clk_i {io} [all_outputs]
"""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


for name, m in MACROS.items():
    d = os.path.join(HIER, name)
    w, h = m["size"]
    cfg = dict(COMMON)
    cfg.update({
        "DESIGN_NAME": name,
        "VERILOG_FILES": [RTL + f for f in m["files"]],
        "FP_SIZING": "absolute",
        "DIE_AREA": [0, 0, w, h],
        "PL_TARGET_DENSITY_PCT": 55,
        "PDN_MULTILAYER": False,
        "RT_MAX_LAYER": "met4",
        "IO_PIN_ORDER_CFG": "dir::pins.cfg",
        "ERRORS_ON_UNMATCHED_IO": "both",
    })
    if m["params"]:
        cfg["SYNTH_PARAMETERS"] = m["params"]
    if m.get("defines"):
        cfg["VERILOG_DEFINES"] = m["defines"]
    write(os.path.join(d, "config.json"), json.dumps(cfg, indent=4) + "\n")
    write(os.path.join(d, "pins.cfg"), m["pins"])
    extra = ""
    if m.get("pin_inputs"):
        extra = ("\n# Inputs driven directly by chip pins: same 2 ns as the chip's own SDC.\n"
                 "set_input_delay -clock clk_i %.1f [get_ports {%s}]\n"
                 % (PIN_INPUT_NS, " ".join(m["pin_inputs"])))
    write(os.path.join(d, "base.sdc"),
          SDC.format(period="$::env(CLOCK_PERIOD)", io=IO_BUDGET_NS) + extra)
    write(os.path.join(d, "pnr.sdc"),
          SDC.format(period="%.1f" % PNR_NS, io=IO_BUDGET_NS) + extra)
    print("macro config :", os.path.relpath(d, ROOT), "%dx%d um" % (w, h))


# ---------------------------------------------------------------------------
# Stage 2: chip top. Needs each macro's finished run.
# ---------------------------------------------------------------------------
MACRO_TAG = "RUN_macro"   # run tag used for every macro (see instructions)


def last_state(design):
    run = os.path.join(HIER, design, "runs", MACRO_TAG)
    steps = []
    for p in glob.glob(os.path.join(run, "*", "state_out.json")):
        num = os.path.basename(os.path.dirname(p)).split("-")[0]
        if num.isdigit():
            steps.append((int(num), p))
    if not steps:
        return None
    return json.load(open(max(steps)[1]))


VIEWS = ("gds", "lef", "nl", "pnl", "lib", "spef", "sdf", "spice")


def macro_entry(design, instance, location):
    st = last_state(design)
    if st is None:
        return None
    entry = {}
    for v in VIEWS:
        val = st.get(v)
        if val is None:
            continue
        if isinstance(val, dict):
            entry[v] = {k: (x if isinstance(x, list) else [x]) for k, x in val.items()}
        else:
            entry[v] = val if isinstance(val, list) else [val]
    if "gds" not in entry or "lef" not in entry:
        sys.exit(design + ": run has no GDS/LEF yet -- did it finish?")
    entry["instances"] = {instance: {"location": list(location), "orientation": "N"}}
    return entry


entries = {n: macro_entry(n, m["instance"], m["location"]) for n, m in MACROS.items()}
missing = [n for n, e in entries.items() if e is None]
if missing:
    print()
    print("stage 1 not finished -- harden these macros first:")
    for n in missing:
        print("  librelane --pdk-root ~/.ciel --run-tag %s flow/librelane/hier/%s/config.json"
              % (MACRO_TAG, n))
    print("then re-run this script to write the chip-level config.")
    sys.exit(0)

flat = json.load(open(os.path.join(ROOT, "flow", "librelane", "navic_sips_top", "config.json")))
top_macros = {}
# SRAMs: same views as the flat build, new positions on the bottom row
SRAM_POS = {
    "sky130_sram_2kbyte_1rw1r_32x512_8": ("u_weight_sram", (40, 40)),
    "sky130_sram_1kbyte_1rw1r_32x256_8": ("u_event_sram", (1480, 40)),
}
for cell, (inst, loc) in SRAM_POS.items():
    e = dict(flat["MACROS"][cell])
    e["instances"] = {inst: {"location": list(loc), "orientation": "N"}}
    top_macros[cell] = e
top_macros.update(entries)

top = {k: v for k, v in flat.items() if k not in ("VERILOG_FILES", "MACROS", "SYNTH_PARAMETERS",
                                                   "PDN_MACRO_CONNECTIONS")}
top.update({
    "DESIGN_NAME": "navic_sips_top",
    # glue only: the three hardened blocks come in as macros, not RTL
    "VERILOG_FILES": [RTL + f for f in ("navic_sips_top.sv", "soc_bus.sv",
                                        "navic_sips_regs.sv", "spi_master.sv",
                                        "uart_tx.sv")],
    "VERILOG_DEFINES": ["NAVIC_HIER"],
    "SYNTH_PARAMETERS": ['FW_HEX="%s"' % os.path.join(ROOT, "fw", "firmware.hex")],
    "MACROS": top_macros,
    "PDN_MACRO_CONNECTIONS": [
        "u_.*_sram VPWR VGND vccd1 vssd1",
        "u_cpu VPWR VGND VPWR VGND",
        "u_acc VPWR VGND VPWR VGND",
        "u_sicu VPWR VGND VPWR VGND",
    ],
    "MAGIC_GDS_FLATGLOB": ["sky130_sram_*"],
    # 2000 x 1200 rather than the flat build's 1800 x 1100: rectangular
    # blocks cannot be squeezed the way loose cells can, and the routing
    # channels between them need room.
    "FP_SIZING": "absolute",
    "DIE_AREA": [0, 0, DIE_W, DIE_H],
})
td = os.path.join(HIER, "navic_sips_top")
write(os.path.join(td, "config.json"), json.dumps(top, indent=4) + "\n")
flat_dir = os.path.join(ROOT, "flow", "librelane", "navic_sips_top")
for sdc in ("base.sdc", "pnr.sdc"):
    write(os.path.join(td, sdc), open(os.path.join(flat_dir, sdc)).read())
print()
print("chip config  :", os.path.relpath(os.path.join(td, "config.json"), ROOT))
for n, m in MACROS.items():
    print("  %-9s at (%4d, %4d)  %dx%d um" % (n, m["location"][0], m["location"][1], *m["size"]))
print("next: librelane --pdk-root ~/.ciel --run-tag RUN_hier flow/librelane/hier/navic_sips_top/config.json")
