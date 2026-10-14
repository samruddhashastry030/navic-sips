#!/usr/bin/env bash
# Same RTL, two cell libraries: SKY130 HD (tt, 1.8 V) vs ASAP7 RVT (tt, 0.7 V).
#   bash experiments/node_compare/synth.sh LIBDIR OUTDIR [block...]
# LIBDIR must hold sky130hd_tt.lib and asap7_rvt_tt.lib (see README.md).
# Synthesis only: cell area and a gate-delay estimate with NO wires, NO
# placement and NO SRAM macros. It compares the processes, not finished chips.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIBDIR="$(cd "$1" && pwd)"; OUT="$(mkdir -p "$2" && cd "$2" && pwd)"; shift 2
R="$ROOT/rtl"
SWHEX="${SWHEX:-$ROOT/experiments/sw_vs_accel/build/sw_ship.hex}"

blocks=("$@"); [ ${#blocks[@]} -gt 0 ] || blocks=(cpu_core acc_core sicu bus_rom1k bus_rom4k regs spi uart)

src () {
  case $1 in
    cpu_core)  echo "read_verilog $R/third_party/picorv32.v; read_verilog -sv $R/cpu_core.sv; hierarchy -top cpu_core" ;;
    cpu_fastmul) echo "read_verilog $R/third_party/picorv32.v; read_verilog -sv $ROOT/experiments/sw_vs_accel/cpu_core_fastmul.sv; hierarchy -top cpu_core" ;;
    acc_core)  echo "read_verilog -sv $R/lstm_accel.sv $R/acc_core.sv; hierarchy -top acc_core" ;;
    sicu)      echo "read_verilog -sv $R/sicu.sv; hierarchy -top sicu" ;;
    bus_rom1k) echo "read_verilog -sv $R/soc_bus.sv; chparam -set FW_HEX \"$ROOT/fw/firmware.hex\" soc_bus; hierarchy -top soc_bus" ;;
    bus_rom4k) echo "read_verilog -sv $R/soc_bus.sv; chparam -set ROM_WORDS 1024 -set FW_HEX \"$SWHEX\" soc_bus; hierarchy -top soc_bus" ;;
    regs)      echo "read_verilog -sv $R/navic_sips_regs.sv; hierarchy -top navic_sips_regs" ;;
    spi)       echo "read_verilog -sv $R/spi_master.sv; hierarchy -top spi_master" ;;
    uart)      echo "read_verilog -sv $R/uart_tx.sv; hierarchy -top uart_tx" ;;
  esac
}

for lib in sky130hd_tt asap7_rvt_tt; do
  L="$LIBDIR/$lib.lib"
  [ $lib = sky130hd_tt ] && L="$LIBDIR/sky130hd_tt_clean.lib"
  for b in "${blocks[@]}"; do
    cat > "$OUT/$b.$lib.ys" <<YS
$(src $b)
synth -flatten -top $( [ ${b:0:3} = bus ] && echo soc_bus || ( [ $b = regs ] && echo navic_sips_regs || ( [ $b = spi ] && echo spi_master || ( [ $b = uart ] && echo uart_tx || ( [ $b = cpu_fastmul ] && echo cpu_core || echo $b )))))
design -save pre
dfflibmap -liberty $L
abc -liberty $L -D 1000000
opt_clean
tee -o $OUT/$b.$lib.area.txt stat -liberty $L
write_verilog -noattr $OUT/$b.$lib.v
design -load pre
dfflibmap -liberty $L
abc -liberty $L -D 1 -script $HERE/fast.abc
opt_clean
tee -o $OUT/$b.$lib.fast.txt stat -liberty $L
YS
    ( cd "$ROOT" && yosys -q -l "$OUT/$b.$lib.log" -s "$OUT/$b.$lib.ys" >/dev/null 2>&1 ) \
      && echo "done $b $lib" || echo "FAILED $b $lib"
  done
done
