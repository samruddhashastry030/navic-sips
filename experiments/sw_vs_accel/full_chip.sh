#!/usr/bin/env bash
# The whole chip, at its pins (tb/top/tb_top.sv), running the SOFTWARE LSTM.
#   bash experiments/sw_vs_accel/full_chip.sh
# Same stimulus as the shipping test. Prints the cycles infer() took and the
# logits; compare with the accelerator build of the same test (-692 33 694,
# SEVERE, confidence 10). tb_top's own class/confidence checks read the
# accelerator's outputs, which are idle here, so those lines are expected to
# fail in this build and are filtered out.
#
# Builds: hw (accelerator), sw (int32 software LSTM), sw64 (int64). The int32
# build checks the weight image before enabling the SICU, which delays the
# SICU's start by a few windows; tb_top's stimulus is timed from reset, so
# its S4 history -- and its logits -- differ slightly from hw. sw64 has no
# such check and sees exactly the hw history, so its logits must equal hw's.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
B="$HERE/build/full_chip"; mkdir -p "$B"; cd "$B"
R="$ROOT/rtl"
RUNS="${*:-hw sw}"
for v in "hw " "sw -DSW_LSTM -DLSTM_ACC32" "sw64 -DSW_LSTM"; do
  set -- $v; n=$1; shift; S=""; [ $# -gt 0 ] && S="$ROOT/fw/lstm_sw.c"
  riscv64-unknown-elf-gcc -march=rv32imc_zicsr_zicntr -mabi=ilp32 -Os -ffreestanding \
    -fno-builtin -nostdlib -ffunction-sections -fdata-sections -DMEASURE "$@" \
    -I"$ROOT/fw" -I"$HERE/build" -T "$ROOT/fw/link.ld" -Wl,--gc-sections \
    -o $n.elf "$ROOT/fw/start.S" "$ROOT/fw/main.c" $S -lgcc
  riscv64-unknown-elf-objcopy -O binary $n.elf $n.bin
  python3 -c "d=open('$n.bin','rb').read(); assert len(d)<=4096; d+=b'\0'*(4096-len(d)); \
open('$n.hex','w').write(''.join('%08x\n'%int.from_bytes(d[i:i+4],'little') for i in range(0,4096,4)))"
done
cp "$R/weights/lut_sigmoid.hex" "$R/weights/lut_tanh.hex" .
python3 "$ROOT/tb/system/make_flash.py" "$R/weights/weights.hex" >/dev/null
sed 's/#60_000_000;/#200_000_000;/' "$ROOT/tb/top/tb_top.sv" > tb_top_long.sv
iverilog -g2012 -s tb_top -s measure -o full.vvp tb_top_long.sv "$HERE/measure.sv" \
  "$ROOT/tb/top/sram_models.sv" "$R/navic_sips_top.sv" "$R/soc_bus.sv" \
  "$R/navic_sips_regs.sv" "$R/spi_master.sv" "$R/uart_tx.sv" "$R/sicu.sv" \
  "$R/lstm_accel.sv" "$R/cpu_core.sv" "$R/acc_core.sv" "$R/third_party/picorv32.v" 2>/dev/null
for n in $RUNS; do
  mkdir -p run_$n; cp $n.hex run_$n/firmware.hex; cp lut_*.hex flash.hex wimage.hex run_$n/
  ( cd run_$n && vvp -n ../full.vvp > sim.log )
  echo "=== $n"; grep -E "MEASURE|ready pin rose|STATUS =|LOOPCFG|IRQST: SEVERE|irq pin|timeout" run_$n/sim.log || true
done
