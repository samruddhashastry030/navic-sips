#!/usr/bin/env bash
# Inference cost on the full chip RTL: accelerator vs. CPU software.
#   bash experiments/sw_vs_accel/bench.sh [variant...]
# Variants (default: all):
#   hw        accelerator, shipping CPU
#   sw64      software LSTM, int64 accumulator, shipping CPU (iterative MUL)
#   sw32      software LSTM, int32 accumulator (exact, see fw/lstm_sw.c)
#   sw32o2    sw32 compiled -O2 instead of -Os
#   sw32fm    sw32 on a CPU with PicoRV32's fast multiplier
# Each runs NV golden vectors (default 2) and prints cycles per inference and
# the logits, which must equal the golden ones printed first.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
B="$HERE/build"; mkdir -p "$B"; cd "$B"
NV=${NV:-2}
CC=${CROSS:-riscv64-unknown-elf-}gcc; OC=${CROSS:-riscv64-unknown-elf-}objcopy
R="$ROOT/rtl"

python3 - "$ROOT" "$NV" <<'PY'
import sys
root, nv = sys.argv[1], int(sys.argv[2])
s = lambda v: v - 65536 if v >= 32768 else v
d = f"{root}/rtl/weights"
lut = lambda n: [s(int(l, 16)) for l in open(f"{d}/lut_{n}.hex") if l.strip()]
with open("lut_tables.h", "w") as f:
    f.write("/* generated from rtl/weights/lut_*.hex */\n#include <stdint.h>\n")
    for n in ("sigmoid", "tanh"):
        f.write(f"static const int16_t lut_{n}[256] = {{{','.join(map(str, lut(n)))}}};\n")
vecs, seq = [], []
for line in open(f"{d}/golden_vectors.hex"):
    l = line.strip()
    if not l or l.startswith("//"): continue
    if l.startswith("EXP"):
        vecs.append((seq, [s(int(x, 16)) for x in l.split()[1:4]])); seq = []; continue
    a, b = l.split(); seq.append((s(int(a, 16)), s(int(b, 16))))
with open("bench_vectors.h", "w") as f:
    f.write(f"#include <stdint.h>\n#define NV {nv}\n")
    for k, n in ((0, "vec_x0"), (1, "vec_x1")):
        f.write(f"static const int16_t {n}[NV][32] = {{\n")
        for sq, _ in vecs[:nv]: f.write(" {" + ",".join(str(t[k]) for t in sq) + "},\n")
        f.write("};\n")
for i, (_, e) in enumerate(vecs[:nv]): print(f"golden vector {i}: logits {e[0]} {e[1]} {e[2]}")
w = [int(x, 16) for x in open(f"{d}/weights.hex").read().split()]
open("wimage.hex", "w").write("".join(f"{x:08x}\n" for x in w))
PY
cp "$R/weights/lut_sigmoid.hex" "$R/weights/lut_tanh.hex" .

fw () {  # name defines sources
  $CC -march=rv32imc_zicsr_zicntr -mabi=ilp32 ${OPT:--Os} -ffreestanding -fno-builtin \
      -nostdlib -ffunction-sections -fdata-sections $2 -I"$ROOT/fw" -I. \
      -T "$ROOT/fw/link.ld" -Wl,--gc-sections -o "$1.elf" "$ROOT/fw/start.S" \
      "$HERE/bench.c" $3 -lgcc
  $OC -O binary "$1.elf" "$1.bin"
  python3 -c "d=open('$1.bin','rb').read(); assert len(d)<=4096; d+=b'\0'*(4096-len(d)); \
open('$1.hex','w').write(''.join('%08x\n'%int.from_bytes(d[i:i+4],'little') for i in range(0,4096,4)))"
}
sim () {  # name cpu_core_file
  iverilog -g2012 -o "$1.vvp" "$HERE/tb_bench.sv" "$ROOT/tb/top/sram_models.sv" \
    "$R/navic_sips_top.sv" "$R/soc_bus.sv" "$R/navic_sips_regs.sv" "$R/spi_master.sv" \
    "$R/uart_tx.sv" "$R/sicu.sv" "$R/lstm_accel.sv" "$2" "$R/acc_core.sv" \
    "$R/third_party/picorv32.v" 2>&1 | grep -v "sorry: constant selects" || true
  [ -s "$1.vvp" ] || { echo "$1: iverilog failed"; exit 1; }
  mkdir -p "run_$1"; cp "$1.hex" "run_$1/bench.hex"; cp lut_*.hex wimage.hex "run_$1/"
  ( cd "run_$1" && vvp -n "../$1.vvp" | tee bench.log | sed "s/^/$1: /" )
}
for v in ${@:-hw sw64 sw32 sw32fm}; do
  case $v in
    hw)     fw hw "" "";                                   sim hw "$R/cpu_core.sv" ;;
    sw64)   fw sw64 "-DSW_LSTM" "$ROOT/fw/lstm_sw.c";      sim sw64 "$R/cpu_core.sv" ;;
    sw32)   fw sw32 "-DSW_LSTM -DLSTM_ACC32" "$ROOT/fw/lstm_sw.c"; sim sw32 "$R/cpu_core.sv" ;;
    sw32o2) OPT=-O2 fw sw32o2 "-DSW_LSTM -DLSTM_ACC32" "$ROOT/fw/lstm_sw.c"; sim sw32o2 "$R/cpu_core.sv" ;;
    sw32fm) fw sw32fm "-DSW_LSTM -DLSTM_ACC32" "$ROOT/fw/lstm_sw.c"; sim sw32fm "$HERE/cpu_core_fastmul.sv" ;;
  esac
done
