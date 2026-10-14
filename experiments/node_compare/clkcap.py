"""Per block: total clock-pin capacitance of its flip-flops (pF).
  python3 clkcap.py OUTDIR LIBDIR  -> merges 'clk_pF' into OUTDIR/summary.json"""
import json, os, re, sys
from libtools import cells
out, libdir = sys.argv[1], sys.argv[2]
libs = {"sky130hd_tt": "sky130hd_tt_clean.lib", "asap7_rvt_tt": "asap7_rvt_tt.lib"}
clk = {}
for lib, f in libs.items():
    t = open(os.path.join(libdir, f)).read()
    cu = re.search(r'capacitive_load_unit\s*\(\s*([\d.]+)\s*,\s*"?(\w+)"?', t)
    sc = float(cu.group(1)) * {"ff": 1.0, "pf": 1000.0}[cu.group(2).lower()]
    d = {}
    for name, a, b in cells(t):
        body = t[a:b]
        for pm in re.finditer(r'\bpin\s*\(\s*"?(\w+)"?\s*\)\s*\{', body):
            seg = body[pm.end():pm.end() + 3000]
            if re.search(r'\bclock\s*:\s*"?true', seg[:seg.find('timing') if 'timing' in seg else 3000]):
                c = re.search(r'\bcapacitance\s*:\s*([\d.eE+-]+)', seg)
                if c: d[name] = float(c.group(1)) * sc
    clk[lib] = d
s = json.load(open(os.path.join(out, "summary.json")))
for blk, per in s.items():
    for lib, r in per.items():
        v = open(os.path.join(out, f"{blk}.{lib}.v")).read()
        tot = sum(clk[lib].get(m.group(1), 0.0)
                  for m in re.finditer(r"^\s*(\S+)\s+\S+\s*\(", v, re.M))
        r["clk_pF"] = round(tot / 1000.0, 4)
json.dump(s, open(os.path.join(out, "summary.json"), "w"), indent=1)
for blk, per in s.items():
    print(blk, {l: (r["ff"], r["clk_pF"]) for l, r in per.items()})
