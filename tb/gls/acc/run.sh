#!/usr/bin/env bash
# Gate-level simulation of the hardened accelerator macro, then its power
# from recorded switching activity.
#
#   bash tb/gls/acc/run.sh            # functional check on the layout netlist
#   bash tb/gls/acc/run.sh power      # + activity (active/idle) + OpenSTA power
#
# Runs tb/accel/tb_acc_clock_gate.sv against
#   flow/librelane/hier/acc_core/runs/$RUN/final/nl/acc_core.nl.v  (RUN=RUN_macro)
# with the SKY130 cell models, at the chip's 33 ns clock. Cells get a unit
# delay of 0.1 ns, so this checks FUNCTION on the real netlist (including the
# clock-gating cell and the clock tree) -- timing is STA's job.
# The power step needs `openroad` (inside the LibreLane nix-shell). It reads the
# macro's final .odb (OpenROAD needs the technology, which the .odb carries).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
RUN=${RUN:-RUN_macro}
FINAL="$ROOT/flow/librelane/hier/acc_core/runs/$RUN/final"
NL="$FINAL/nl/acc_core.nl.v"
[ -f "$NL" ] || { echo "no netlist at $NL"; exit 1; }

# SKY130 HD cell models and tt liberty: from PDK_ROOT if set, else ciel's cache
if [ -n "${PDK_ROOT:-}" ]; then HD="$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd"
else HD="$(ls -d "$HOME"/.ciel/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd 2>/dev/null | head -1)"; fi
[ -f "$HD/verilog/sky130_fd_sc_hd.v" ] || { echo "SKY130 HD models not found (set PDK_ROOT)"; exit 1; }
echo "netlist : $NL"; echo "models  : $HD/verilog"

cd "$HERE"
W="$ROOT/rtl/weights"; cp "$W/weights.hex" .
python3 - "$W/golden_vectors.hex" <<'PY'
import sys
seq, exp = [], None
for line in open(sys.argv[1]):
    l = line.strip()
    if not l or l.startswith("//"): continue
    if l.startswith("EXP"): exp = l.split()[1:4]; break
    seq += l.split()
open("vec0.hex", "w").write("\n".join(seq) + "\n")
open("exp0.hex", "w").write("\n".join(exp) + "\n")
PY

iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY=#0.1 -DHALF_NS=16.5 \
  -o gls.vvp "$ROOT/tb/accel/tb_acc_clock_gate.sv" "$NL" \
  "$HD/verilog/primitives.v" "$HD/verilog/sky130_fd_sc_hd.v" 2>&1 \
  | grep -Eiv "warning|sorry: constant selects" || true
[ -s gls.vvp ] || { echo "iverilog failed"; exit 1; }

echo "=== functional check on the layout netlist"
vvp -n gls.vvp | grep -Ev '^VCD|\$finish'

[ "${1:-}" = power ] || exit 0

echo "=== recording activity"
vvp -n gls.vvp +vcd_active | grep -E "record|PASS|FAIL"
vvp -n gls.vvp +vcd_idle   | grep -E "record|PASS|FAIL"

SPEF="$(find "$FINAL/spef" -name '*.spef' | grep -i nom | head -1 || true)"
SDC="$(ls "$FINAL"/sdc/*.sdc | head -1)"
LIB="$HD/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
for w in active idle; do
  cat > power_$w.tcl <<TCL
read_liberty $LIB
read_db $FINAL/odb/acc_core.odb
read_sdc $SDC
$( [ -n "$SPEF" ] && echo "read_spef $SPEF" )
read_vcd -scope tb_acc_clock_gate/dut acc_$w.vcd
report_power
TCL
  echo "=== power, $w window (tt, 33 ns clock, recorded activity)"
  openroad -exit power_$w.tcl > power_$w.log 2>&1 || { echo "openroad failed:"; tail -20 power_$w.log; exit 1; }
  awk '/^Group/{p=1} p{print} p&&/^Total/{getline; print; p=0}' power_$w.log
done
