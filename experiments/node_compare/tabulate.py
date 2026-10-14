"""Tabulate the SKY130-vs-ASAP7 synthesis results.

  python3 tabulate.py OUTDIR LIBDIR

For every block synthesised by synth.sh, per library:
  area_um2     cell area, area-oriented mapping
  fast_ps      longest gate path, delay-oriented mapping (ABC stime; no wires,
               no clock-to-q or setup) -- a process comparison, not a signoff
               timing number
  leak_nW      sum of the cells' liberty leakage at the tt corner
  cin_pF       sum of the cells' input-pin capacitance -- the switched-
               capacitance proxy used for dynamic energy (wires excluded)
  ff           flip-flop count
"""
import glob, os, re, sys, json

out, libdir = sys.argv[1], sys.argv[2]
tabs = {}
for lib, f in (("sky130hd_tt", "sky130.tab"), ("asap7_rvt_tt", "asap7.tab")):
    t = {}
    for line in open(os.path.join(libdir, f)):
        n, a, lk, c = line.split("\t")
        t[n] = (float(a), float(lk), float(c))
    tabs[lib] = t

rows = {}
for v in sorted(glob.glob(os.path.join(out, "*.v"))):
    blk, lib = os.path.basename(v)[:-2].split(".", 1)
    cnt = {}
    for m in re.finditer(r"^\s*(\S+)\s+\S+\s*\(", open(v).read(), re.M):
        c = m.group(1)
        if c in tabs[lib]:
            cnt[c] = cnt.get(c, 0) + 1
    t = tabs[lib]
    area = sum(t[c][0] * k for c, k in cnt.items())
    leak = sum(t[c][1] * k for c, k in cnt.items())
    cin = sum(t[c][2] * k for c, k in cnt.items()) / 1000.0
    ff = sum(k for c, k in cnt.items() if re.search(r"df|DFF|dlx|DHL|DLL", c))
    log = open(os.path.join(out, f"{blk}.{lib}.log")).read()
    d = re.findall(r"Delay =\s*([\d.]+) ps", log)
    rows.setdefault(blk, {})[lib] = dict(
        area_um2=round(area, 1), leak_nW=round(leak, 3), cin_pF=round(cin, 3),
        ff=ff, cells=sum(cnt.values()),
        fast_ps=float(d[-1]) if d else None)

json.dump(rows, open(os.path.join(out, "summary.json"), "w"), indent=1)
hdr = f"{'block':10} {'lib':13} {'cells':>6} {'ff':>5} {'area um2':>10} {'gate ps':>8} {'leak nW':>9} {'Cin pF':>7}"
print(hdr); print("-" * len(hdr))
for blk, d in rows.items():
    for lib, r in d.items():
        print(f"{blk:10} {lib:13} {r['cells']:6} {r['ff']:5} {r['area_um2']:10.1f} "
              f"{(r['fast_ps'] or 0):8.0f} {r['leak_nW']:9.3f} {r['cin_pF']:7.3f}")
    if len(d) == 2:
        s, a = d["sky130hd_tt"], d["asap7_rvt_tt"]
        print(f"{'':10} {'ratio s/a':13} {'':6} {'':5} {s['area_um2']/a['area_um2']:10.1f} "
              f"{(s['fast_ps'] or 0)/(a['fast_ps'] or 1):8.1f} {s['leak_nW']/a['leak_nW']:9.3f} "
              f"{s['cin_pF']/a['cin_pF']:7.2f}")
