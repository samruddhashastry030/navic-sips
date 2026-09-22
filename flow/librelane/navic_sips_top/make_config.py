"""Rewrite flow/librelane/navic_sips_top/config.json for the real top level.

Run from the repo root:  python3 flow/librelane/navic_sips_top/make_config.py

Keeps the macro placement, PDN hookup and Magic settings from the floorplan
experiment, and changes what the real chip needs:
  - every RTL file, not just the old top + regs + SPI
  - absolute paths for the firmware and gate-LUT images, which $readmemh
    loads at synthesis (Yosys runs from the step directory, so relative
    paths fail -- found on the accelerator run)
  - signoff at 33 ns, implementation against 30 ns (pnr.sdc), the
    over-constraint that closed the accelerator at every corner
The previous config is kept as config.floorplan.json.
"""
import json, os, shutil

ROOT = os.getcwd()
D = os.path.join(ROOT, "flow", "librelane", "navic_sips_top")
cfg_path = os.path.join(D, "config.json")
assert os.path.exists(os.path.join(ROOT, "rtl", "navic_sips_top.sv")), "run from the repo root"

if not os.path.exists(os.path.join(D, "config.floorplan.json")):
    shutil.copy(cfg_path, os.path.join(D, "config.floorplan.json"))

c = json.load(open(cfg_path))

c["VERILOG_FILES"] = ["dir::../../../rtl/" + f for f in [
    "navic_sips_top.sv", "soc_bus.sv", "navic_sips_regs.sv", "spi_master.sv",
    "uart_tx.sv", "sicu.sv", "lstm_accel.sv", "third_party/picorv32.v"]]

for f in ("fw/firmware.hex", "rtl/weights/lut_sigmoid.hex", "rtl/weights/lut_tanh.hex"):
    assert os.path.exists(os.path.join(ROOT, f)), "missing " + f + " -- build it first"
c["SYNTH_PARAMETERS"] = [
    'FW_HEX="%s"'   % os.path.join(ROOT, "fw", "firmware.hex"),
    'LUT_SIG="%s"'  % os.path.join(ROOT, "rtl", "weights", "lut_sigmoid.hex"),
    'LUT_TANH="%s"' % os.path.join(ROOT, "rtl", "weights", "lut_tanh.hex"),
]

c["CLOCK_PERIOD"] = 33
c["PNR_SDC_FILE"] = "dir::pnr.sdc"
c["SIGNOFF_SDC_FILE"] = "dir::base.sdc"
c["MAGIC_MACRO_STD_CELL_SOURCE"] = "PDK"

# Hold at ss. The first whole-chip run failed hold only at ss, and only on the
# host-bus inputs (bus_wdata_i -> navic_sips_regs): the clock takes ~3 ns to
# reach those flops at ss, so input data needs extra delay to be held long
# enough. The resizer already checks every corner, but stops at zero slack
# plus a small margin (defaults 0.1 / 0.05 ns); detailed routing then slows
# the real clock tree and the cushion is gone. Over-fix instead. Inputs have
# ~30 ns of setup margin, so the added delay costs nothing there.
c["PL_RESIZER_HOLD_SLACK_MARGIN"] = 0.5
c["GRT_RESIZER_HOLD_SLACK_MARGIN"] = 0.5

# Magic DRC reports ~8.4 million false positives inside the SKY130 SRAM
# macros (it does not apply the foundry's SRAM rule exemptions); KLayout DRC
# is the authoritative checker and reports zero. Skipping Magic DRC saves
# ~30 minutes and several GB per run. RE-ENABLE for final tape-out signoff if
# the shuttle's precheck expects it.
c["RUN_MAGIC_DRC"] = False

json.dump(c, open(cfg_path, "w"), indent=4)

sdc = open(os.path.join(D, "base.sdc")).read()
open(os.path.join(D, "pnr.sdc"), "w").write(
    sdc.replace("-period $::env(CLOCK_PERIOD)", "-period 30.0"))

print("config.json rewritten (old one saved as config.floorplan.json)")
print("  RTL files      :", len(c["VERILOG_FILES"]))
print("  clock          : signoff 33 ns, implementation 30 ns")
print("  hold margin    : 0.5 ns (placement and global routing)")
print("  Magic DRC      : off (KLayout DRC is authoritative)")
for p in c["SYNTH_PARAMETERS"]: print("  param          :", p)
