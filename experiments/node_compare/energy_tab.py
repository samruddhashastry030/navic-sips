"""Per-cell energy table from a liberty file, for the energy model.

  python3 energy_tab.py LIB > table.tsv
  columns: cell, clk_int_pJ, out_int_pJ, cin_fF, clk_fF

  clk_int_pJ  flip-flops: internal energy of the clock pin over one clock
              cycle (mean rise_power + mean fall_power of its internal_power)
  out_int_pJ  mean internal energy per output transition (mean over the
              output pins' rise_power and fall_power tables)
  cin_fF      total input-pin capacitance;  clk_fF  clock-pin capacitance
Energy unit is voltage_unit x capacitive_load_unit (pJ for SKY130, fJ for
ASAP7); converted to pJ here.
"""
import re, sys
from libtools import cells

t = open(sys.argv[1]).read()
cu = re.search(r'capacitive_load_unit\s*\(\s*([\d.]+)\s*,\s*"?(\w+)"?', t)
c_ff = float(cu.group(1)) * {"ff": 1.0, "pf": 1000.0}[cu.group(2).lower()]
e_pj = c_ff * 1e-3                       # 1 V x 1 cap-unit, in pJ

def groups(body, kw):
    for m in re.finditer(kw + r'\s*\([^)]*\)\s*\{', body):
        i, d = m.end(), 1
        while d:
            j, k = body.find('{', i), body.find('}', i)
            if j != -1 and j < k: d += 1; i = j + 1
            else: d -= 1; i = k + 1
        yield body[m.end():i]

def mean_vals(g):
    v = [float(x) for vs in re.findall(r'values\s*\(([^)]*)\)', g)
         for x in re.findall(r'-?[\d.]+(?:[eE][-+]?\d+)?', vs)]
    return sum(v) / len(v) if v else 0.0

for name, a, b in cells(t):
    body = t[a:b]
    clk_int = out_int = cin = clk = 0.0; nout = 0
    for p in groups(body, r'\bpin'):
        head = p[:p.find('timing') if 'timing' in p else len(p)]
        cap = re.search(r'\bcapacitance\s*:\s*([\d.eE+-]+)', head)
        dirn = re.search(r'direction\s*:\s*"?(\w+)', head)
        isclk = re.search(r'\bclock\s*:\s*"?true', head)
        ip = list(groups(p, r'internal_power'))
        rise = [mean_vals(x) for g in ip for x in groups(g, r'rise_power')]
        fall = [mean_vals(x) for g in ip for x in groups(g, r'fall_power')]
        if dirn and dirn.group(1) == "input" and cap:
            cin += float(cap.group(1)) * c_ff
            if isclk:
                clk += float(cap.group(1)) * c_ff
                r = sum(rise) / len(rise) if rise else 0.0
                f = sum(fall) / len(fall) if fall else 0.0
                clk_int += (r + f) * e_pj
        if dirn and dirn.group(1) == "output" and (rise or fall):
            vals = rise + fall
            out_int += sum(vals) / len(vals) * e_pj; nout += 1
    print(f"{name}\t{clk_int:.6g}\t{(out_int / nout if nout else 0):.6g}\t{cin:.6g}\t{clk:.6g}")
