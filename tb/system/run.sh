#!/usr/bin/env bash
# End-to-end simulations of the NavIC-SIPS control path.
#   real PicoRV32 + soc_bus + firmware; behavioural flash and SICU.
# Run from anywhere:  bash tb/system/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

make -C "$ROOT/fw" >/dev/null
cp "$ROOT/fw/firmware.hex" .
cp "$ROOT/rtl/weights/lut_sigmoid.hex" "$ROOT/rtl/weights/lut_tanh.hex" .

# Flash image built from the REAL exported weights, plus a corrupted copy.
python3 make_flash.py "$ROOT/rtl/weights/weights.hex"
python3 - <<'PY'
lines = open('flash.hex').read().split()
lines[1000] = '%02x' % (int(lines[1000], 16) ^ 0x01)
open('flash_bad.hex', 'w').write('\n'.join(lines) + '\n')
PY

SRC="$ROOT/rtl/soc_bus.sv $ROOT/rtl/third_party/picorv32.v"
KEEP="cycle|pass|FAIL|PASS|latency|= |logits|started|header"

echo "=== 1. normal boot, behavioural accelerator ==="
iverilog -g2012 -o sys.vvp tb_system.sv $SRC 2>/dev/null
vvp -n sys.vvp | grep -E "$KEEP" | grep -v "class = SEVERE\|SEVERE loop\|confidence"

echo
echo "=== 2. corrupted flash image ==="
iverilog -g2012 -o sysf.vvp tb_system_fault.sv $SRC 2>/dev/null
vvp -n sysf.vvp | grep -E "cycle|pass|FAIL"

echo
echo "=== 3. REAL accelerator vs reference twin, real weights ==="
iverilog -g2012 -o sysa.vvp tb_system_accel.sv $SRC "$ROOT/rtl/lstm_accel.sv" 2>/dev/null
vvp -n sysa.vvp | grep -E "$KEEP"

echo
echo "=== 4. REAL SICU fed synthetic I/Q + REAL accelerator ==="
iverilog -g2012 -o syss.vvp tb_system_sicu.sv $SRC "$ROOT/rtl/lstm_accel.sv" "$ROOT/rtl/sicu.sv" 2>/dev/null
vvp -n syss.vvp | grep -E "$KEEP|window|saturated|worst|  [0-9 ]{3}  "

FULL="$SRC $ROOT/rtl/lstm_accel.sv $ROOT/rtl/sicu.sv $ROOT/rtl/spi_master.sv"

echo
echo "=== 5. FULL RTL: real SPI master on pins, bit-level flash ==="
iverilog -g2012 -o sysp.vvp tb_system_spi.sv $FULL 2>/dev/null
vvp -n sysp.vvp | grep -E "$KEEP|flash saw|worst"

echo
echo "=== 6. FULL RTL, corrupted image: retry framing at pin level ==="
iverilog -g2012 -DBAD_FLASH -o syspf.vvp tb_system_spi.sv $FULL 2>/dev/null
vvp -n syspf.vvp | grep -E "cycle|flash saw|pass|FAIL|PASS"
