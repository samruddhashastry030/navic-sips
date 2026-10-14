"""Logic cell area of the three design options, from node_compare/out/summary.json.
  python3 experiments/area_summary.py experiments/node_compare/out/summary.json
Standard-cell area only: SRAM macros (475,251 um2 on SKY130, identical in all
three options) and placement whitespace are not included."""
import json, sys
s = json.load(open(sys.argv[1]))
common = ["sicu", "regs", "spi", "uart"]
opts = {
    "with accelerator (as built)":      ["cpu_core", "acc_core", "bus_rom1k"] + common,
    "no accelerator, software LSTM":    ["cpu_core", "bus_rom4k"] + common,
    "no accelerator, fast-MUL CPU":     ["cpu_fastmul", "bus_rom4k"] + common,
}
for lib in ("sky130hd_tt", "asap7_rvt_tt"):
    base = sum(s[b][lib]["area_um2"] for b in opts["with accelerator (as built)"])
    print(f"\n{lib}")
    for name, blocks in opts.items():
        a = sum(s[b][lib]["area_um2"] for b in blocks)
        lk = sum(s[b][lib]["leak_nW"] for b in blocks)
        print(f"  {name:34} {a:10.0f} um2  {100*(a-base)/base:+6.1f}%   leakage {lk:8.1f} nW")
    for b in ("cpu_core", "acc_core", "sicu", "bus_rom1k", "bus_rom4k", "cpu_fastmul"):
        print(f"    {b:12} {s[b][lib]['area_um2']:10.1f} um2  gate path {s[b][lib]['fast_ps']:7.0f} ps")
