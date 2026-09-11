# NavIC-SIPS firmware flow

What the host processor does, from reset to steady state. This document
exists to pin down the interfaces before `navic_sips_top.sv` wires the real
blocks together — every mismatch found here is cheaper than one found in
simulation.

Blocks referenced are the verified ones: `sicu.sv`, `lstm_accel.sv`,
`spi_master.sv`, `navic_sips_regs.sv`, `uart_tx.sv`.

---

## 1. Boot

```
reset deasserted
  |
  v
clear STATUS, drive BYPASS high            <- fail-safe: the host receiver
  |                                           must never be worse off for
  |                                           this chip being present
  v
run BIST if CTRL.SELFTEST_START is set
  |
  +-- fail --> set BIST_DONE, clear BIST_PASS, stay in BYPASS, halt
  |
  v
load weights (section 2)
  |
  +-- fail --> set weights_fault, stay in BYPASS, halt
  |
  v
set weights_ready, release BYPASS
  |
  v
steady state (section 3)
```

BYPASS is asserted from reset and released only when weights are loaded and
verified. Anything that goes wrong leaves it asserted. The receiver then
uses its own default tracking settings and loses nothing.

---

## 2. Weight load

The image format is specified in `rtl/weights/WEIGHT_FORMAT.md`. 512 words
of 32 bits, two Q8.8 slots per word, read from external SPI flash.

```
  assert spi_hold_cs
  send 0x03 (READ), 24-bit address 0x000000
  for word in 0..511:
      read 4 bytes
      write to weight SRAM at w_addr_o = word
      accumulate checksum
  release spi_hold_cs
  compare checksum against the value stored at a known flash offset
```

Three things the firmware must do that are easy to leave out:

**Verify, don't just load.** A corrupted weight image produces a model that
runs happily and predicts nonsense. There is no way to notice this at
runtime, so the checksum is the only defence. Store it in flash alongside
the image; `export_weights.py` should be extended to emit it.

**Retry before giving up.** SPI is a physical interface. A small number of
retries before asserting `weights_fault` is worth having.

**Read back a sample.** After writing, read a handful of SRAM words and
compare. This catches a dead SRAM that the SPI path would not.

---

## 3. Steady state

```
loop forever:
    wait for sicu.s4_valid_o                   <- one per 10 s window
    read s4 (Q4.12), saturated flag
    push s4 into the 32-deep history ring

    if fewer than 32 samples so far:
        continue                                <- need 320 s of history

    if saturated flag set:
        mark this sample suspect                <- see open question 4
 
    start lstm_accel                            <- pulse start_i
    feed the 32 history samples as timesteps    <- ready/valid
    wait for out_valid_o                        <- ~98,000 cycles, ~3 ms
    read logit0..2, class

    compute confidence = argmax margin, 4 bits
    write CLASS and CONF to the register block
    look up loop settings for this class        <- firmware table, tunable
    write LOOP_CFG (pll_bw, fll_en, t_coh, band_pref)
    raise the interrupt
    optionally emit a UART line for telemetry
```

The class-to-loop-settings mapping stays a firmware table rather than
hardware, deliberately, so it can be retuned without a re-spin. The KPI
sweep gives the starting values: 5 Hz PLL bandwidth when clean, 15 Hz at
moderate scintillation, 50 Hz at severe.

Timing has enormous slack. A window arrives every 10 s; inference takes
about 3 ms at 33 MHz. The processor is idle over 99.9% of the time, which
is worth stating in the paper — it is an argument for clock gating, not for
a faster clock.

---

## 4. Interface contracts

These are what `navic_sips_top.sv` must wire, and what integration will
test. Each needs checking against the actual RTL before coding.

| From | To | Signals | Note |
|---|---|---|---|
| tracking loop | sicu | `amp_i[15:0]`, `in_valid_i` / `in_ready_o` | 50 Hz |
| sicu | firmware | `s4_o[15:0]` Q4.12, `s4_valid_o`, `saturated_o`, `shift_o` | one per 10 s |
| firmware | lstm_accel | `start_i`, `in_feat0_i`/`in_feat1_i` Q8.8, `in_valid_i` / `in_ready_o` | 32 timesteps |
| lstm_accel | firmware | `logit0..2_o` Q8.8, `class_o[1:0]`, `out_valid_o` | one per inference |
| firmware | weight SRAM | `w_addr_o[8:0]`, `w_din_o[31:0]`, `w_csb_o`, `w_web_o`, `w_wmask_o[3:0]` | boot only |
| lstm_accel | weight SRAM | `w_addr_o[8:0]`, `w_dout_i[31:0]`, `w_csb_o` | inference only |
| firmware | regs | CLASS, CONF, LOOP_CFG, STATUS | |

---

## 5. Open questions

**1. Weight SRAM arbitration.** Both the processor (at boot) and the
accelerator (during inference) drive the weight SRAM's address and control.
Nothing arbitrates between them. They never overlap in time — the
accelerator only runs after `weights_ready` — but that is a convention, not
a mechanism. Either add a mux driven by `weights_ready`, or make the
accelerator's port read-only and physically separate. **This has to be
resolved before the blocks are wired together.**

**2. Normalisation.** The model expects `(raw_S4 - mu) / sd` per feature.
`mu` and `sd` sit in weight slots 0-3. Does the firmware apply this, or does
the accelerator? Firmware is simpler — it is two subtractions and two
divisions once per 10 s — but it means the processor must do fixed-point
division, or the reciprocal of `sd` must be stored instead. **Storing
1/sd would be a small change to `export_weights.py` and avoids a division.**

**3. The second feature.** The model takes `[S4_L1, S4_L2]` — two
frequencies. The SICU as built computes one S4 from one amplitude stream.
Either the receiver provides two, and the SICU is instantiated twice, or the
model needs retraining on a single feature. **This is a real gap and needs
deciding.** Retraining on S4_L1 alone is cheap to test and would tell us
what the second frequency is worth.

**4. Saturated windows.** `saturated_o` flags a window where intensity
clipped. Should the firmware substitute the previous value, mark the
prediction low-confidence, or ignore the flag? Saturation is most likely
during rapid onset, which is exactly when the prediction matters.

**5. Threshold application.** Weight slot 4 holds the SEVERE decision
threshold (0.512). The accelerator emits a plain argmax. Applying the
threshold in firmware keeps it tunable at runtime, which seems right.

**6. Cold start.** The first 32 windows — 320 s — have no history. The chip
should stay in BYPASS and say so, rather than predicting from a partial
ring.
