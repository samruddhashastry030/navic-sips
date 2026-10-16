#!/usr/bin/env bash
# Gate-level simulation of the WHOLE chip: tb/top/tb_top.sv, the pin-level
# test, run on the hierarchical layout's netlists.
#
#   bash tb/gls/chip/run.sh                 # RUN=RUN_hier4, MACRO_RUN=RUN_macro
#   RUN=RUN_hier5 bash tb/gls/chip/run.sh
#
# Netlists: the chip top from flow/librelane/hier/navic_sips_top/runs/$RUN,
# and cpu_core, acc_core, sicu from their runs/$MACRO_RUN; the boot ROM and
# gate tables are baked into them. SRAMs use tb/top/sram_models.sv.
# Cell models: SKY130 HD functional models, flip-flops 0.1 ns clock-to-Q,
# gates and clock buffers zero delay -- so this checks FUNCTION on the real
# netlist (clock tree and clock gate included); timing is STA's job.
#
# Step 1 runs the same test on the RTL to record what the chip publishes
# (logits, S4 report); step 2 checks the netlist publishes the same.
# Expect a long run: the test simulates ~1.3 million clock cycles.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
RUN=${RUN:-RUN_hier4}; MACRO_RUN=${MACRO_RUN:-RUN_macro}
H="$ROOT/flow/librelane/hier"
NL=("$H/navic_sips_top/runs/$RUN/final/nl/navic_sips_top.nl.v")
for m in cpu_core acc_core sicu; do NL+=("$H/$m/runs/$MACRO_RUN/final/nl/$m.nl.v"); done
for f in "${NL[@]}"; do [ -f "$f" ] || { echo "missing netlist: $f"; exit 1; }; done

if [ -n "${PDK_ROOT:-}" ]; then HD="$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd"
else HD="$(ls -d "$HOME"/.ciel/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd 2>/dev/null | head -1)"; fi
[ -f "$HD/verilog/sky130_fd_sc_hd.v" ] || { echo "SKY130 HD models not found (set PDK_ROOT)"; exit 1; }
CELLS=${CELLS:-"$HD/verilog/primitives.v $HD/verilog/sky130_fd_sc_hd.v"}

cd "$HERE"
R="$ROOT/rtl"
make -C "$ROOT/fw" >/dev/null
cp "$ROOT/fw/firmware.hex" "$R/weights/lut_sigmoid.hex" "$R/weights/lut_tanh.hex" .
python3 "$ROOT/tb/system/make_flash.py" "$R/weights/weights.hex" >/dev/null
echo "netlists: ${NL[*]}" | tr ' ' '\n'

echo "=== 1. RTL reference run"
iverilog -g2012 -o rtl.vvp "$ROOT/tb/top/tb_top.sv" "$ROOT/tb/top/sram_models.sv" \
  "$R/navic_sips_top.sv" "$R/soc_bus.sv" "$R/navic_sips_regs.sv" "$R/spi_master.sv" \
  "$R/uart_tx.sv" "$R/sicu.sv" "$R/lstm_accel.sv" "$R/cpu_core.sv" "$R/acc_core.sv" \
  "$R/third_party/picorv32.v" 2>/dev/null
vvp -n rtl.vvp > rtl.log
grep -E "REF|PASS|FAIL" rtl.log
read -r L0 L1 L2 S4 < <(awk '/REF logits/{print $3, $4, $5, $7}' rtl.log)
[ -n "${S4:-}" ] || { echo "RTL run gave no reference values"; exit 1; }

echo "=== 2. gate-level run (long; progress in $HERE/gls.log)"
iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY=#0.1 -DHALF_NS=16.5 \
  -DGLS_L0="$L0" -DGLS_L1="$L1" -DGLS_L2="$L2" -DGLS_S4="$S4" \
  -o gls.vvp "$ROOT/tb/top/tb_top.sv" "$ROOT/tb/top/sram_models.sv" "${NL[@]}" $CELLS 2>&1 \
  | grep -Eiv "warning|sorry: constant selects|timescale" || true
[ -s gls.vvp ] || { echo "iverilog failed"; exit 1; }
start=$(date +%s)
vvp -n gls.vvp | tee gls.log | grep -Ev '^VCD|\$finish'
echo "gate-level run took $(( ($(date +%s) - start) / 60 )) min"
