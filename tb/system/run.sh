#!/usr/bin/env bash
# First end-to-end simulation of the NavIC-SIPS control path.
#   real PicoRV32 + real soc_bus + real firmware, behavioural flash/SICU/accel
# Run from anywhere:  bash tb/system/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

make -C "$ROOT/fw" >/dev/null
cp "$ROOT/fw/firmware.hex" .
python3 make_flash.py
python3 - <<'PY'
lines = open('flash.hex').read().split()
lines[1000] = '%02x' % (int(lines[1000], 16) ^ 0x01)
open('flash_bad.hex', 'w').write('\n'.join(lines) + '\n')
PY

SRC="$ROOT/rtl/soc_bus.sv $ROOT/rtl/third_party/picorv32.v"

echo "=== normal boot ==="
iverilog -g2012 -o sys.vvp tb_system.sv $SRC 2>/dev/null
vvp -n sys.vvp | grep -E "cycle|pass|FAIL|PASS|latency|= "

echo
echo "=== corrupted flash image ==="
iverilog -g2012 -o sysf.vvp tb_system_fault.sv $SRC 2>/dev/null
vvp -n sysf.vvp | grep -E "cycle|pass|FAIL"
