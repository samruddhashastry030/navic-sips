#!/usr/bin/env bash
# The whole chip, tested only at its pins.  Run:  bash tb/top/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

make -C "$ROOT/fw" >/dev/null
cp "$ROOT/fw/firmware.hex" .
cp "$ROOT/rtl/weights/lut_sigmoid.hex" "$ROOT/rtl/weights/lut_tanh.hex" .
python3 "$ROOT/tb/system/make_flash.py" "$ROOT/rtl/weights/weights.hex"

R="$ROOT/rtl"
iverilog -g2012 -o top.vvp tb_top.sv sram_models.sv \
  "$R/navic_sips_top.sv" "$R/soc_bus.sv" "$R/navic_sips_regs.sv" \
  "$R/spi_master.sv" "$R/uart_tx.sv" "$R/sicu.sv" "$R/lstm_accel.sv" \
  "$R/third_party/picorv32.v" 2>/dev/null
vvp -n top.vvp | grep -E "===|pass|FAIL|PASS|logits|STATUS =|INDEX|ready pin rose"
