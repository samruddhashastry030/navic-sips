#!/usr/bin/env bash
# The firmware takes its tunables from the flash image's config block.
#   bash tb/top/run_config.sh
# Runs the pin-level chip test twice with a modified flash image:
#   1. a config block with a high SEVERE margin and different loop codes --
#      the same logits must now publish DEGRADED with the new codes and no
#      interrupt, so the firmware is reading the block
#   2. no config block at all (an older export) -- the firmware's built-in
#      defaults must give the shipping result, SEVERE
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
make -C "$ROOT/fw" >/dev/null
R="$ROOT/rtl"
cp "$ROOT/fw/firmware.hex" "$R/weights/lut_sigmoid.hex" "$R/weights/lut_tanh.hex" "$W/"
SRC=("$HERE/tb_top.sv" "$HERE/sram_models.sv" "$R/navic_sips_top.sv" "$R/soc_bus.sv"
     "$R/navic_sips_regs.sv" "$R/spi_master.sv" "$R/uart_tx.sv" "$R/sicu.sv"
     "$R/lstm_accel.sv" "$R/cpu_core.sv" "$R/acc_core.sv" "$R/third_party/picorv32.v")

run () {   # name, image dir, iverilog defines...
  local name=$1 img=$2; shift 2
  ( cd "$W" && python3 "$ROOT/tb/system/make_flash.py" "$img/weights.hex" >/dev/null )
  iverilog -g2012 "$@" -o "$W/t.vvp" "${SRC[@]}" 2>/dev/null
  echo "=== $name"
  ( cd "$W" && vvp -n t.vvp ) | grep -E "accelerator logits|STATUS: class|STATUS: conf|LOOPCFG|SEVERE latched|irq pin|interrupt for class|PASS|FAIL"
}

# 1. margin 8.0 (2048), confidence shift 4, loop codes 0x101 / 0x102 / 0x103
mkdir -p "$W/cfg"; cp "$R/weights/weights.hex" "$R/weights/weights.bin" "$W/cfg/"
python3 "$ROOT/python/ml/config_block.py" "$W/cfg" --margin 8.0 --conf-shift 4 \
    --loop 0x101,0x102,0x103
run "modified config block" "$W/cfg" -DCFG_MARGIN=2048 -DCFG_SHIFT=4 \
    -DCFG_LOOP0="32'h101" -DCFG_LOOP1="32'h102" -DCFG_LOOP2="32'h103"

# 2. no config block: zero slots 992-998 (words 496-499)
mkdir -p "$W/old"
python3 - "$R/weights/weights.hex" "$W/old/weights.hex" <<'PY'
import sys
w = open(sys.argv[1]).read().split()
for i in range(496, 500): w[i] = "00000000"
open(sys.argv[2], "w").write("\n".join(w) + "\n")
PY
run "image without a config block (defaults)" "$W/old"
