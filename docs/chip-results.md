# NavIC-SIPS chip results

Where the chip stands. The last review saw a trained model; this covers what
happened since — the model now runs inside a verified, signed-off SoC.

---

## 1. The headline

**The chip works in simulation and signs off physically.**

Driven only through its pins, with sustained S4 around 0.87 from prompt I/Q,
the chip boots, loads its weights from external flash over SPI, verifies
them, measures scintillation, runs the trained model, and publishes **SEVERE
with confidence 9** to the host — raising the interrupt line, which the host
clears with a register write. Both fail-safes force safe outputs.

The same design passes SKY130 signoff with timing closed at every corner,
and the laid-out netlist behaves exactly like the RTL: the same pin-level
test, run at gate level on the final layout (RUN_hier4), publishes the same
logits, class and confidence.

---

## 2. Verification

Every block is real RTL — no stubs anywhere. Firmware runs on the real
PicoRV32 from a boot ROM.

| Test | What it proves |
|---|---|
| Block testbenches | Each block against golden vectors from the Python model |
| `tb_soc_bus` | 46 checks on the system bus and all eight targets |
| System tests (6) | Firmware boots, loads weights, infers, publishes |
| `tb_top` | The whole chip through its pins only, as the receiver sees it |
| `tb_scrub` | A weight bit corrupted while running is detected and repaired |
| `tb/top/run_config.sh` | The firmware takes its margin, confidence scale and loop codes from the flash image |
| `tb/accel` | The accelerator's clock gate: golden results, clock stops when idle, no glitches |
| Gate-level, accelerator (`tb/gls/acc`) | The hardened accelerator netlist, clock tree and gate cell included |
| Gate-level, whole chip (`tb/gls/chip`) | `tb_top` on the final layout netlists: same results as RTL (78 min) |

The older `tb/system` suite predates the hierarchical build and currently
fails (tests 1, 3, 4, 5); `tb/top` is the maintained chip-level suite.

**Every test was shown to fail when the design is broken**, not merely to
pass. Deliberate faults — a wrong weight bit, a swapped lookup table, a
missing strobe, a chip-select held low — were each injected and each caught.

Four bugs were found this way that no block-level test could have:

- the system bus accepting one CPU request twice, which corrupted every
  memory read
- the firmware feeding a saturated first window into its history, so every
  first prediction after power-up used one garbage sample
- a missing hardware strobe, which meant **the host would never have
  received a single result or interrupt** — the chip's entire purpose,
  silently absent, with all internal tests passing
- an unsynchronised reset that could leave flip-flops metastable at power-up

---

## 3. Physical signoff (SKY130, LibreLane)

Hierarchical build: CPU, LSTM accelerator and SICU hardened as macros,
placed with the two SRAMs on the chip top. Current run: RUN_hier4.

| | |
|---|---|
| Die | 2000 x 1200 um (2.4 mm2) |
| Macros | cpu_core 640x560, acc_core 520x420, sicu 460x400 um; SRAMs 2 KB weights, 1 KB data |
| Clock | 33 ns (~30 MHz) |
| Setup, worst corner | **+3.32 ns** |
| Hold, worst corner | **+0.096 ns** |
| Power | **~36 mW** (tt, default activity; see note) |
| KLayout DRC / LVS / antenna | **0 / 0 / 0** |
| Max-slew / max-cap warnings | 98 / 21 (not signoff errors) |

**Accelerator power, measured.** From switching activity recorded in a
gate-level simulation of the hardened accelerator (tb/gls/acc, OpenSTA,
tt): **3.28 mW while computing, 66 uW idle** with its clock gated. A
forecast takes 3.3 ms, about **11 uJ**. Of the idle 66 uW, nearly all is
eight clock buffers ahead of the gate cell (~7 uW each).

Power note: the 39.5 uW previously listed here was wrong. The post-route
report of the earlier hierarchical run (RUN_hier2, 57-openroad-stapostpnr,
nom_tt_025C_1v80) gives 36.5 mW total: clock tree 4.4 mW, flip-flops 5.0 mW,
combinational 24.2 mW, macros 2.9 mW, leakage 28 uW. Activity is the tool's
default, not a real workload; a VCD-driven report will refine it.

Magic DRC reports ~8.4 million violations, all inside the vendor SRAM
macros: it does not apply the foundry's bitcell rule exemptions. The count
is the same with stub logic as with the full chip, KLayout reports zero on
the same layout, and LVS is clean. **If the shuttle's precheck requires
Magic DRC, this needs a waiver** — worth asking about early.

Remaining: 98 max-slew and 21 max-cap warnings on the chip top (the flat
build had 1,128 and 149). Not signoff errors, but they mean the timing
numbers carry more uncertainty than the slack figures suggest.

---

## 4. Decisions taken, with the numbers behind them

**One frequency band, not two.** The L2 band is worth 0.021 F1. Dropping it
saves ~178,000 um2 and removes the requirement that the receiver expose both
bands. The shipping model uses S4 on L1 only.

**No CORDIC.** It existed for a square root the SICU now does internally,
and for a phase arctangent serving sigma-phi — a feature we cannot validate
and do not use. Both dropped.

**Keep the accelerator, clock-gated.** Software on the CPU computes the same
logits bit for bit in 3.3 million cycles (109 ms of each 10 s), so the
accelerator is not needed for speed. It is kept for energy: 101,100 cycles
per forecast, and with a clock gate (one sky130_fd_sc_hd__dlclkp_2) it
idles at 66 uW instead of an estimated ~2.5 mW. See experiments/README.md.

**Chip clock 33 ns (~30 MHz).** Nothing is throughput-bound: the SICU
produces one result per 10 s, inference takes 3 ms. Every block closes at
this clock at every corner.

**Firmware in ROM.** 1,120 bytes in a 2 KB ROM, synthesised into silicon.
It cannot be changed after tape-out. What a retrained model or the receiver
interface may need to change -- the SEVERE decision margin, the confidence
scale and the loop-setting codes -- comes from a config block in the flash
image (rtl/weights/WEIGHT_FORMAT.md, python/ml/config_block.py), with the
shipping values as built-in fallbacks. The weights and that block are
updatable in flash; the code that loads them is not.

---

## 5. What is left

**Shuttle integration.** Pads or the shuttle's wrapper, its pin positions,
power entry and precheck rules (including the Magic DRC waiver for the
SRAMs). This is the main physical task left, and it depends on which
shuttle the chip goes on.

**CPU sleep.** The CPU busy-waits through each 10 s window. Letting it
sleep between S4 scores, with its clock gated, is the largest power saving
left.

**Interface specifications not yet agreed with the receiver side:**

- the **host bus timing** — how long the host holds data after the clock
  edge. The current constraint is a placeholder, and it determined a real
  hold-timing fix.
- the **loop-setting codes** — the firmware writes a 3-bit PLL bandwidth
  code, but nothing defines what each code means in hertz. The KPI
  experiment gives the values we want (5 / 15 / 50 Hz); the mapping to codes
  is an interface decision. The codes now live in the flash image, so this
  can be settled after tape-out.

**Operating point.** Recall is a dial. The model currently catches 60% of
severe events at 58% precision; tuned for recall it catches **72% at 44%**.
For a receiver a false alarm costs a briefly noisier tracking loop while a
miss can cost lock — so the higher-recall point is arguably right, but that
is a systems judgement rather than a machine-learning one.

**Ground-station data.** Everything rests on COSMIC-2 satellite-to-satellite
measurements. The model transfers well across season, year and region, but
the observing geometry differs from a receiver on the ground looking up.
That is the one limitation we cannot test our way around.
