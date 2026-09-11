# NavIC-SIPS model results

Prepared for the mentor review. The ask was to train the model. This is what
it does, how it was checked, and what it now forces us to decide.

---

## 1. The headline

A 987-parameter LSTM predicts severe scintillation 30 seconds ahead with a
**SEVERE F1 of 0.591**, against **0.523** for the best classical baseline on
the same data.

Trained and tested on 6.4 million real samples from COSMIC-2 satellite
radio-occultation measurements, split by occultation so no window appears in
both training and test.

---

## 2. Why the earlier number was wrong

Our own synthetic data gave 0.881. That figure was inflated by about 0.43
and should not be quoted.

Two reasons, both now understood:

**The generator held scintillation strength constant** through each event, so
the class 30 seconds in the future was always identical to the present class.
The "forecast" was solvable by reading the current value. Real occultations
are non-stationary — a typical one runs 0.11, 0.23, 0.53, 0.63, 0.30, 0.13.

**It oversampled strong events**, giving 42.3% SEVERE against a real-world
rate of 0.8%.

Neither was hidden; both were in the generator's own comments as deliberate
choices. But the consequence for the reported number was not appreciated.

---

## 3. What the data is

| | |
|---|---|
| Source | COSMIC-2 `scn1c2`, 41 days of 2024 |
| Coverage | March equinox (060-090) and September equinox (260-272) |
| Samples | 6,412,978 windows of 32 timesteps |
| Cadence | 10 s, measured against CDAAC rather than assumed |
| Class balance | 0.8% SEVERE — the real prior |
| Features | S4 on L1 and L2. Phase scintillation is unusable: present in 2 of 300 files |

Held out and never trained on: seven days of June solstice (quiet season) and
one day of 2026 (declining solar activity).

---

## 4. What was validated, and how

**Architecture is correctly sized.** A sweep over hidden 8/16/32 and 1/2
layers shows clear saturation: 8→16 gains 0.016, 16→32 gains 0.008. Two
layers beat one at every width. The shipping configuration is 2 layers of 8
hidden units, 987 parameters — the largest that fits the 2 KB weight SRAM.

**It generalises.** Trained on equinox 2024 only, then tested with no
retraining:

| Test | LSTM | Classical baseline | Margin |
|---|---|---|---|
| In-season (2024 equinox) | 0.630 | 0.523 | +0.107 |
| June solstice, quiet season | 0.417 | 0.225 | +0.192 |
| 2026, two years later | 0.441 | 0.146 | +0.295 |
| Indian sector | 0.541 | 0.392 | +0.149 |

The margins are *larger* out of distribution, and the baseline was trained on
each of those sets while the LSTM never saw them. Summary-statistic models
collapse when conditions shift; the sequence model degrades gracefully.

**False alarms stay low out of season.** 0.080% in the quiet season against
0.09% in season — it does not panic when events are rare.

**Training globally beats training regionally.** The global model scores
0.541 on Indian-sector data, better than the 0.488 achieved by training on
Indian data directly, because it saw 48,000 severe examples instead of 493.

---

## 5. It runs on the chip

Not a simulation result — the RTL exists and reproduces the model exactly.

**`lstm_accel.sv`** passes 64 of 64 golden vectors bit-exact. Same weights,
same lookup tables, same rounding convention, same logits.

**`sicu.sv`** computes S4 from raw 50 Hz signal and passes 32 of 32 vectors
within one LSB. Validated against CDAAC's own published values across 952
windows: median error 0.006.

**Both testbenches were proven to catch injected faults**, not merely to
pass.

**The SICU hardens to clean signoff** — DRC, LVS, antenna and routing all
zero, 177,705 µm², 4.6 µW.

Numeric decisions made by measurement rather than assumption: Q8.8 is
sufficient (wider formats score identically), and the gate nonlinearity needs
a 256-entry lookup table, not piecewise-linear approximation, which costs
0.17 F1.

---

## 6. What this forces us to decide

**The L2 band is worth 0.021 F1.** Dropping it means one SICU instead of
two, saving ~178,000 µm² and removing a requirement that the receiver expose
both frequency bands. Recommend dropping.

**The CORDIC has no remaining purpose.** It existed for the square root,
which the SICU now does internally, and for the phase arctangent, which
serves sigma-phi — a feature we cannot validate and do not use. Recommend
dropping both.

**The chip clock is 33 MHz**, set by the SICU's sequential divider. Nothing
in the design is throughput-bound: the SICU produces one result per 10 s and
inference takes 3 ms. Pipelining the divider would recover 100 MHz if wanted.

**PicoRV32 may be larger than the job requires.** The firmware's work is
boot, load weights, and a loop. A hardwired sequencer would do it in a
fraction of the area. But the competition category is "RISC-V SoC Design", so
this may be a requirement rather than a choice.

**The 8×8 systolic array cannot be justified on throughput.** One inference
is 26,624 MACs against a 10-second window; the sequential version is already
fast enough by three orders of magnitude. Its case has to be energy per
inference, or the research contribution itself.

---

## 7. What we would still like

Ground-station scintillation data from an Indian receiver. Everything above
rests on satellite-to-satellite limb measurements from COSMIC-2, which is
real data but a different observing geometry from a receiver on the ground
looking up.

The model transfers well across season, year and region, which is
encouraging. But the geometry gap is the one limitation we cannot test our
way around, and it is the obvious question a reviewer will ask.
