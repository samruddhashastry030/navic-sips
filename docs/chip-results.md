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

The same design passes SKY130 signoff with timing closed at every corner.

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

| | |
|---|---|
| Die | 1800 x 1100 um (1.98 mm2) |
| Standard cells | 64,183 (35.1% utilisation) |
| SRAM macros | 475,251 um2 — 2 KB weights, 1 KB data |
| Clock | 33 ns (~30 MHz) |
| Setup, worst corner | **+1.76 ns** |
| Hold, worst corner | **+0.94 ns** |
| Power | **39.5 uW** |
| KLayout DRC / LVS / routing DRC / antenna | **0 / 0 / 0 / 0** |

Magic DRC reports ~8.4 million violations, all inside the vendor SRAM
macros: it does not apply the foundry's bitcell rule exemptions. The count
is the same with stub logic as with the full chip, KLayout reports zero on
the same layout, and LVS is clean. **If the shuttle's precheck requires
Magic DRC, this needs a waiver** — worth asking about early.

Remaining: 1,128 max-slew and 149 max-cap warnings, down from 4,528 and 320.
Not signoff errors, but they mean the timing numbers carry more uncertainty
than the slack figures suggest. The cause is understood — see section 5.

---

## 4. Decisions taken, with the numbers behind them

**One frequency band, not two.** The L2 band is worth 0.021 F1. Dropping it
saves ~178,000 um2 and removes the requirement that the receiver expose both
bands. The shipping model uses S4 on L1 only.

**No CORDIC.** It existed for a square root the SICU now does internally,
and for a phase arctangent serving sigma-phi — a feature we cannot validate
and do not use. Both dropped.

**Chip clock 33 ns (~30 MHz).** Nothing is throughput-bound: the SICU
produces one result per 10 s, inference takes 3 ms. Every block closes at
this clock at every corner.

**Firmware in ROM.** 840 bytes, synthesised into silicon. It cannot be
changed after tape-out. The weights remain updatable in external flash; the
code that loads them does not.

---

## 5. What is left

**The floorplan.** The die was sized during an early experiment with stub
logic and is about 79% empty. That is what makes the wires long and produces
the remaining slew warnings. Shrinking it around the macros would improve
signal quality, power and area at once. This is the main physical task left.

**Interface specifications not yet agreed with the receiver side:**

- the **host bus timing** — how long the host holds data after the clock
  edge. The current constraint is a placeholder, and it determined a real
  hold-timing fix.
- the **loop-setting codes** — the firmware writes a 3-bit PLL bandwidth
  code, but nothing defines what each code means in hertz. The KPI
  experiment gives the values we want (5 / 15 / 50 Hz); the mapping to codes
  is an interface decision.

**Operating point.** Recall is a dial. The model currently catches 60% of
severe events at 58% precision; tuned for recall it catches **72% at 44%**.
For a receiver a false alarm costs a briefly noisier tracking loop while a
miss can cost lock — so the higher-recall point is arguably right, but that
is a systems judgement rather than a machine-learning one.

**Ground-station data.** Everything rests on COSMIC-2 satellite-to-satellite
measurements. The model transfers well across season, year and region, but
the observing geometry differs from a receiver on the ground looking up.
That is the one limitation we cannot test our way around.
