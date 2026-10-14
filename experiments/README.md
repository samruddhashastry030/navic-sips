# Experiments: is the accelerator worth it, and SKY130 vs ASAP7

Asked for at the 14 Oct 2026 mentor review. Nothing here changes the shipping
chip: `fw/firmware.hex` builds byte-identical with or without these files.

## 1. Accelerator vs. software (`sw_vs_accel/`)

`fw/lstm_sw.c` is the LSTM in C, bit-exact with `rtl/lstm_accel.sv`. It is
only compiled with `-DSW_LSTM`; `-DLSTM_ACC32` uses a 32-bit accumulator,
exact for any weight image with |w| < 3640 (14.2), which the firmware checks.

    # host check: all 64 golden vectors, bit for bit
    cc -O2 -Ifw -Iexperiments/sw_vs_accel/build -DLSTM_SW_WEIGHTS=wimg \
       experiments/sw_vs_accel/host_check.c -o /tmp/hc && /tmp/hc
    # (bench.sh writes build/lut_tables.h; run it once first)

    bash experiments/sw_vs_accel/bench.sh        # cycles per forecast, chip RTL
    bash experiments/sw_vs_accel/full_chip.sh    # whole chip at its pins, ~30 min

Measured (Icarus Verilog, full chip RTL, rdcycle):

| Variant | Cycles per forecast |
|---|---|
| hw: accelerator | 101,100 |
| sw32fm: software, PicoRV32 fast multiplier | 2,341,531 |
| sw32o2: software, int32, -O2 | 2,839,430 |
| sw32: software, int32, -Os | 3,299,787 |
| sw64: software, int64, -Os | 4,526,119 |

Pin-level (`full_chip.sh`): the sw64 build publishes exactly what the
accelerator build does -- logits -692 33 694, SEVERE, confidence 10, SEVERE
loop settings, interrupt -- in 4,526,029 cycles per forecast vs 101,330.
The int32 build checks the weight image before starting the SICU, so it
sees a slightly later S4 history from the time-based stimulus (logits
-688 45 682, still SEVERE, confidence 9).

## 2. SKY130 vs. ASAP7 (`node_compare/`)

Same RTL through Yosys + ABC with two liberty sets: SKY130 HD tt 1.8 V and
ASAP7 RVT tt 0.7 V, both taken from OpenROAD-flow-scripts
(`flow/platforms/{sky130hd,asap7}/lib`). Synthesis only: no wires, no
placement, no SRAM.

    # LIBDIR: sky130hd_tt.lib, and the ASAP7 RVT TT AO/INVBUF/OA/SIMPLE/SEQ libs
    python3 experiments/node_compare/libtools.py merge $LIBDIR/asap7_rvt_tt.lib <the five ASAP7 libs>
    python3 experiments/node_compare/libtools.py merge $LIBDIR/sky130hd_tt_clean.lib $LIBDIR/sky130hd_tt.lib
    python3 experiments/node_compare/libtools.py leak $LIBDIR/asap7_rvt_tt.lib > $LIBDIR/asap7.tab
    python3 experiments/node_compare/libtools.py leak $LIBDIR/sky130hd_tt_clean.lib > $LIBDIR/sky130.tab
    python3 experiments/node_compare/energy_tab.py $LIBDIR/asap7_rvt_tt.lib > $LIBDIR/asap7.etab
    python3 experiments/node_compare/energy_tab.py $LIBDIR/sky130hd_tt_clean.lib > $LIBDIR/sky130.etab
    bash experiments/node_compare/synth.sh $LIBDIR experiments/node_compare/out
    python3 experiments/node_compare/tabulate.py experiments/node_compare/out $LIBDIR
    python3 experiments/node_compare/clkcap.py   experiments/node_compare/out $LIBDIR
    python3 experiments/area_summary.py experiments/node_compare/out/summary.json
    python3 experiments/energy_model.py experiments/node_compare/out $LIBDIR

`node_compare/orfs/acc_core/` is an OpenROAD-flow-scripts config to place and
route the accelerator on ASAP7, for a layout-level check. Untested here.

## Limits

- Power is a first-order ESTIMATE (`energy_model.py` header lists the
  assumptions). Cycle counts and areas are measured.
- The flow's reported ~40 uW for the whole chip disagrees with the clock-pin
  energy in the SKY130 library by ~100x; check with a VCD-driven power report.
