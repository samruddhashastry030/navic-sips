#!/usr/bin/env bash
# The accelerator's clock gate.  Run:  bash tb/accel/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
W="$ROOT/rtl/weights"
cp "$W/lut_sigmoid.hex" "$W/lut_tanh.hex" "$W/weights.hex" .
# golden vector 0 from golden_vectors.hex: 32 feature pairs, then expected logits
python3 - "$W/golden_vectors.hex" <<'PY'
import sys
seq, exp = [], None
for line in open(sys.argv[1]):
    l = line.strip()
    if not l or l.startswith("//"): continue
    if l.startswith("EXP"): exp = l.split()[1:4]; break
    seq += l.split()
assert len(seq) == 64
open("vec0.hex", "w").write("\n".join(seq) + "\n")
open("exp0.hex", "w").write("\n".join(exp) + "\n")
PY
iverilog -g2012 -o gate.vvp tb_acc_clock_gate.sv "$ROOT/rtl/acc_core.sv" "$ROOT/rtl/lstm_accel.sv" 2>&1 \
  | grep -v "constant selects" || true
vvp -n gate.vvp | grep -Ev '^VCD|\$finish'
