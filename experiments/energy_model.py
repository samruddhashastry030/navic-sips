"""First-order energy per 10 s window: accelerator vs. CPU software.

  python3 experiments/energy_model.py OUTDIR LIBDIR
  (OUTDIR from node_compare/synth.sh; LIBDIR holding sky130.etab, asap7.etab
   from node_compare/energy_tab.py and the .tab leakage tables)

MEASURED inputs: cycles per inference (bench.sh on the chip RTL); the cells
of each synthesised block (node_compare/synth.sh); and from the tt liberty
files, each cell's leakage, pin capacitances and internal energy.

ASSUMED (edit below): data activity ALPHA (fraction of cell outputs that
toggle per active cycle), wire capacitance equal to pin capacitance (WIRE),
clock-tree buffers and wires ignored. These make absolute numbers uncertain
by perhaps 2-3x either way; the scenarios share the same assumptions, so the
comparisons between them are firmer than the absolute values.

Per-cycle energy of a block:
  clock     sum over flip-flops of clock-pin internal energy + C_clk * V^2
  data      sum over cells of output internal energy + (1+WIRE) * C_in * V^2
  clocked and active   clock + ALPHA * data
  clocked but idle     clock             (data static, clocks still toggle)
  clock-gated          0
Leakage runs the whole window in every case.
"""
import json, os, re, sys

ALPHA, WIRE = 0.10, 1.0
F_HZ = 1 / 33e-9                    # the chip's 33 ns clock
T_WIN = 10.0                        # one S4 score, one inference, per 10 s
N_WIN = int(F_HZ * T_WIN)
VDD = {"sky130hd_tt": 1.8, "asap7_rvt_tt": 0.7}

# Measured cycles per inference (experiments/sw_vs_accel/bench.sh).
CYC = {
    "hw":     101_100,     # accelerator; CPU feeds it and waits
    "sw64":   4_526_119,   # software, int64 accumulator, -Os
    "sw32":   3_299_787,   # software, shipping CPU (iterative multiplier)
    "sw32o2": 2_839_430,   # as sw32, compiled -O2
    "sw32fm": 2_341_531,   # software, CPU with PicoRV32's fast multiplier
}

OUT, LIBDIR = sys.argv[1], sys.argv[2]
TAB = {}
for lib, base in (("sky130hd_tt", "sky130"), ("asap7_rvt_tt", "asap7")):
    t = {}
    for line in open(os.path.join(LIBDIR, base + ".etab")):
        n, ci, oi, cin, clk = line.split("\t")
        t[n] = [float(ci), float(oi), float(cin), float(clk), 0.0]
    for line in open(os.path.join(LIBDIR, base + ".tab")):
        n, _, lk, _ = line.split("\t")
        if n in t: t[n][4] = float(lk)
    TAB[lib] = t

def blk(name, lib):
    v2, t = VDD[lib] ** 2, TAB[lib]
    net = open(os.path.join(OUT, f"{name}.{lib}.v")).read()
    clock = data = leak = 0.0
    for m in re.finditer(r"^\s*(\S+)\s+\S+\s*\(", net, re.M):
        if m.group(1) not in t: continue
        ci, oi, cin, clk, lk = t[m.group(1)]
        clock += ci * 1e-12 + clk * 1e-15 * v2
        data += oi * 1e-12 + (1 + WIRE) * (cin - clk) * 1e-15 * v2
        leak += lk * 1e-9
    return dict(act=clock + ALPHA * data, idle=clock, leak=leak)

ALWAYS = ["sicu", "regs", "spi", "uart"]        # same in every design

for lib in VDD:
    cpu, cpufm = blk("cpu_core", lib), blk("cpu_fastmul", lib)
    acc = blk("acc_core", lib)
    rom1, rom4 = blk("bus_rom1k", lib), blk("bus_rom4k", lib)
    rest_leak = sum(blk(b, lib)["leak"] for b in ALWAYS)

    print(f"\n=== {lib}  ({VDD[lib]} V, {F_HZ/1e6:.1f} MHz, {T_WIN:.0f} s window) ===")
    print(f"energy per active cycle: CPU {cpu['act']*1e12:.1f} pJ, "
          f"fast-mul CPU {cpufm['act']*1e12:.1f} pJ, accelerator {acc['act']*1e12:.1f} pJ")
    print(f"accelerator clocked but idle: {acc['idle']*1e12:.2f} pJ/cycle "
          f"= {acc['idle']*F_HZ*1e6:.1f} uW continuous; leakage {acc['leak']*1e9:.1f} nW")

    # A. As built: no clock gating, the CPU spins between windows, so its
    #    dynamic energy is the same whether it computes or polls. The only
    #    difference is the accelerator itself, and the bigger ROM without it.
    acc_win = (acc["idle"] * (N_WIN - CYC["hw"]) + acc["act"] * CYC["hw"]
               + acc["leak"] * T_WIN)
    rom_extra = (rom4["leak"] - rom1["leak"]) * T_WIN
    cpu_spin = cpu["act"] * F_HZ
    print("A. as built (everything clocked all the time):")
    print(f"   CPU spinning alone          {cpu_spin*1e6:8.1f} uW  (same in both designs)")
    print(f"   accelerator adds            {acc_win/T_WIN*1e6:8.2f} uW")
    gated = acc["act"] * CYC["hw"] + acc["leak"] * T_WIN
    print(f"   ... with a clock gate on it {gated/T_WIN*1e6:8.2f} uW")
    print(f"   bigger ROM without it adds  {rom_extra/T_WIN*1e6:8.4f} uW")

    # B. Duty-cycled: idle blocks clock-gated, CPU asleep between windows.
    #    Only active cycles cost dynamic energy; leakage still runs.
    hw = (CYC["hw"] * (cpu["act"] + acc["act"])
          + (cpu["leak"] + acc["leak"] + rom1["leak"] + rest_leak) * T_WIN)
    sw = CYC["sw32"] * cpu["act"] + (cpu["leak"] + rom4["leak"] + rest_leak) * T_WIN
    o2 = CYC["sw32o2"] * cpu["act"] + (cpu["leak"] + rom4["leak"] + rest_leak) * T_WIN
    fm = (CYC["sw32fm"] * cpufm["act"]
          + (cpufm["leak"] + rom4["leak"] + rest_leak) * T_WIN)
    print("B. duty-cycled (clock gating + CPU sleep; SICU excluded from dynamic):")
    for name, e in (("accelerator", hw), ("software", sw), ("software -O2", o2),
                    ("software, fast MUL", fm)):
        print(f"   {name:20} {e*1e6:9.2f} uJ per window = {e/T_WIN*1e6:7.2f} uW average")
