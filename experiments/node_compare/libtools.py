"""Liberty helpers for the SKY130-vs-ASAP7 synthesis comparison.

  merge   OUT LIB...   one library holding every cell of LIBs (header from the
                       first), minus ORFS's ASAP7 don't-use patterns -- the
                       Yosys in use reads a single -liberty file.
  leak    LIB          per-cell table (cell, area um2, leakage nW, total input-pin
                       capacitance fF) as
                       TSV: cell_leakage_power if present, else the mean of the
                       cell's leakage_power groups.
"""
import re, sys, fnmatch

# ORFS asap7 DONT_USE_CELLS; for SKY130 the low-power-flow and probe cells,
# which LibreLane also keeps out of synthesis.
DONT_USE = ["*x1p*_ASAP7*", "*xp*_ASAP7*", "SDF*", "ICG*",
            "*__lpflow_*", "*__probe*"]

def cells(text):
    """Yield (name, start, end) of each top-level cell group."""
    for m in re.finditer(r'\n\s*cell\s*\(\s*"?([^")\s]+)"?\s*\)\s*\{', text):
        i, depth = m.end(), 1
        while depth:
            j = text.find('{', i); k = text.find('}', i)
            if j != -1 and j < k: depth += 1; i = j + 1
            else: depth -= 1; i = k + 1
        yield m.group(1), m.start(), i

def merge(out, libs):
    first = open(libs[0]).read()
    hdr = first[:next(cells(first))[1]]
    with open(out, 'w') as f:
        f.write(hdr)
        n = 0
        for lib in libs:
            t = open(lib).read()
            for name, a, b in cells(t):
                if any(fnmatch.fnmatch(name, p) for p in DONT_USE):
                    continue
                f.write(t[a:b]); n += 1
        f.write('\n}\n')
    print(f"merged {n} cells into {out}", file=sys.stderr)

def leak(lib):
    t = open(lib).read()
    unit = re.search(r'leakage_power_unit\s*:\s*"?1(\w+)"?', t).group(1)
    scale = {"pW": 1e-3, "nW": 1.0, "uW": 1e3}[unit]
    cu = re.search(r'capacitive_load_unit\s*\(\s*([\d.]+)\s*,\s*"?(\w+)"?', t)
    cscale = float(cu.group(1)) * {"ff": 1.0, "pf": 1000.0}[cu.group(2).lower()]
    for name, a, b in cells(t):
        body = t[a:b]
        area = float(re.search(r'\barea\s*:\s*([\d.eE+-]+)', body).group(1))
        m = re.search(r'cell_leakage_power\s*:\s*([\d.eE+-]+)', body)
        if m: lk = float(m.group(1))
        else:
            v = [float(x) for x in re.findall(
                r'leakage_power\s*\(\s*\)\s*\{[^{}]*?value\s*:\s*"?([\d.eE+-]+)', body)]
            lk = sum(v) / len(v) if v else 0.0
        cin = 0.0
        for pm in re.finditer(r'\bpin\s*\(\s*"?\w+"?\s*\)\s*\{', body):
            seg = body[pm.end():pm.end() + 4000]
            if re.search(r'direction\s*:\s*"?input', seg[:seg.find('timing') if 'timing' in seg else 4000]):
                cm = re.search(r'\bcapacitance\s*:\s*([\d.eE+-]+)', seg)
                if cm: cin += float(cm.group(1))
        print(f"{name}\t{area}\t{lk * scale}\t{cin * cscale}")

if __name__ == "__main__":
    if sys.argv[1] == "merge": merge(sys.argv[2], sys.argv[3:])
    else: leak(sys.argv[2])
