# NavIC-SIPS rev 1 — datasheet

A scintillation-forecasting co-processor for a NavIC receiver. It measures
amplitude scintillation (S4) on one tracking channel every 10 s, runs a
2-layer LSTM over the last 32 measurements, and tells the receiver whether
the next 30 s will be NOMINAL, DEGRADED or SEVERE, with recommended
tracking-loop settings and an interrupt on SEVERE.

Everything here is taken from the RTL and firmware in this repository
(`rtl/`, `fw/`). Where a feature exists in the register map but does
nothing in rev 1, section 9 says so.

| | |
|---|---|
| Process | SKY130 (open PDK), standard cells sky130_fd_sc_hd, 1.8 V |
| Die | 2.0 x 1.2 mm (hierarchical layout, RUN_hier4) |
| Clock | 33 ns (30.3 MHz), single clock domain |
| CPU | PicoRV32, RV32IMC, firmware in a 2 KB on-chip ROM |
| Memories | 2 KB weight SRAM (dual-port), 1 KB data SRAM |
| Accelerator | LSTM 2 x 8, Q8.8, one multiplier, clock-gated; 101,100 cycles per forecast |
| Power | ~36 mW at tt, flow estimate with default activity; accelerator measured at 3.28 mW active, 66 uW idle (`docs/chip-results.md`) |
| External parts | SPI NOR flash holding the weight image (READ 0x03, 24-bit address) |

---

## 1. Pins

| Pin | Dir | Width | Function |
|---|---|---|---|
| `clk_i` | in | 1 | System clock, 33 ns |
| `rst_ni` | in | 1 | Reset, active low. Asserts asynchronously, released synchronously after 2 clock edges |
| `bus_sel_i` | in | 1 | Host bus: transaction valid |
| `bus_we_i` | in | 1 | Host bus: 1 = write, 0 = read |
| `bus_addr_i` | in | 5 | Host bus: byte address, 32-bit aligned (0x00-0x1C) |
| `bus_wdata_i` | in | 32 | Host bus: write data |
| `bus_rdata_o` | out | 32 | Host bus: read data |
| `bus_ack_o` | out | 1 | Host bus: acknowledge |
| `iq_valid_i` | in | 1 | Prompt I/Q sample strobe, one cycle per sample |
| `iq_i_i` | in | 16 | Prompt I, signed two's complement |
| `iq_q_i` | in | 16 | Prompt Q, signed two's complement |
| `spi_cs_no` | out | 1 | Flash chip select, active low |
| `spi_sclk_o` | out | 1 | Flash clock, clk / 4 (7.6 MHz), SPI mode 0 |
| `spi_mosi_o` | out | 1 | Flash data out |
| `spi_miso_i` | in | 1 | Flash data in |
| `bypass_pin_i` | in | 1 | Hardware fail-safe, active high (section 7) |
| `irq_o` | out | 1 | Interrupt to the host, active high, level |
| `ready_pin_o` | out | 1 | High when the chip is giving advice (weights loaded, not bypassed) |
| `fault_pin_o` | out | 1 | High if the weight image could not be loaded |
| `uart_tx_o` | out | 1 | Debug UART transmit (unused in rev 1, section 9) |

Pads, I/O ring and power pins depend on the shuttle and are not yet part of
the design.

---

## 2. Host bus

A simple synchronous bus on `clk_i`. The host drives `bus_sel_i` for one
cycle with `bus_we_i`, `bus_addr_i` and, for a write, `bus_wdata_i`. The
chip raises `bus_ack_o` on the next clock edge; for a read, `bus_rdata_o`
is valid in the same cycle as the ack. One transaction per ack. Unmapped
addresses read 0 and ignore writes.

The input timing the host must meet (setup and hold of the bus inputs
against `clk_i`) is not yet agreed with the receiver side; the signoff
constraint is a placeholder (`docs/chip-results.md`, section 5).

---

## 3. Register map

| Addr | Name | Access | Reset | Contents |
|---|---|---|---|---|
| 0x00 | ID | RO | 0x5195_0001 | Device ID, "SIPS" rev 1 |
| 0x04 | CTRL | RW | 0 | Control (below) |
| 0x08 | STATUS | RO | 0 | Prediction and chip state (below) |
| 0x0C | INDEX | RO | 0 | [15:0] latest S4, Q4.12 unsigned; [31:16] sigma-phi, always 0 in rev 1 |
| 0x10 | LOOPCFG | RO | safe | Recommended loop settings (below) |
| 0x14 | IRQST | RW1C | 0 | Interrupt status; write 1 to clear |
| 0x18 | IRQEN | RW | 0 | Interrupt enable, same bit layout as IRQST |
| 0x1C | SCRATCH | RW | 0 | Free register for bus bring-up |

**CTRL (0x04)**

| Bit | Name | Meaning |
|---|---|---|
| 0 | ENABLE | Stored and readable; no effect in rev 1 (section 9) |
| 1 | BYPASS | Software fail-safe; ORed with `bypass_pin_i` |
| 2 | BIST | Write 1 to pulse self-test start; not stored; no self-test in rev 1 (section 9) |
| 3 | SOFTRST | Write 1 to restart the CPU and datapath; not stored. Clears STATUS, INDEX and the published result; CTRL, IRQEN and IRQST keep their values. The firmware reboots and reloads the weights |

**STATUS (0x08)**

| Bits | Name | Meaning |
|---|---|---|
| 1:0 | CLASS | 0 NOMINAL, 1 DEGRADED, 2 SEVERE. Forced to 0 in bypass |
| 2 | VALID | A prediction has been published since reset. 0 in bypass |
| 6:3 | CONF | Confidence 0-15: winning-to-runner-up logit margin, shifted (section 6). 0 in bypass |
| 7 | BYPASS | Bypass active, by pin or by CTRL.BYPASS |
| 8 | WEIGHTS_READY | Weight image loaded and verified |
| 9 | WEIGHTS_FAULT | Weight image failed to load after 3 tries |
| 10 | BIST_DONE | Never set in rev 1 |
| 11 | BIST_PASS | Never set in rev 1 |

**LOOPCFG (0x10)**

| Bits | Field | Meaning |
|---|---|---|
| 2:0 | PLL_BW | PLL bandwidth code |
| 3 | FLL_EN | Recommend FLL-assisted tracking |
| 6:4 | T_COH | Coherent integration time code |
| 8:7 | BAND_PREF | 0 L5, 1 S, 2 weighted, 3 hold |

Values per class come from the flash image (section 8). Defaults:

| Class | LOOPCFG | PLL_BW | FLL | T_COH | BAND |
|---|---|---|---|---|---|
| NOMINAL | 0x020 | 0 | 0 | 2 | L5 |
| DEGRADED | 0x021 | 1 | 0 | 2 | L5 |
| SEVERE | 0x01B | 3 | 1 | 1 | L5 |
| Safe (boot, bypass) | 0x033 | 3 | 0 | 3 | L5 |

What each code means in hertz or milliseconds is not yet defined with the
receiver side; the intended loop bandwidths are 5 / 15 / 50 Hz for
NOMINAL / DEGRADED / SEVERE.

**IRQST / IRQEN (0x14 / 0x18)**

| Bit | Event |
|---|---|
| 0 | SEVERE published (not raised in bypass) |
| 1 | Weight load fault |
| 2 | Self-test done (never in rev 1) |

`irq_o = |(IRQST & IRQEN)`, forced low in bypass. A new event setting a bit
wins over a clear written in the same cycle.

---

## 4. I/Q input

One prompt correlator output pair per `iq_valid_i` strobe, at 50 Hz. The
SICU computes S4 over windows of 500 samples (10 s) and scales intensity
with a shift carried from the previous window, so the absolute signal level
does not matter as long as a window does not clip. There is no
back-pressure: a sample arriving in the ~450 cycles while a window is being
finished is dropped, which at 50 Hz does not happen in practice.

The first window after reset always clips (the shift starts at zero) and is
discarded by the firmware. A clipped window later is replaced by the
previous S4.

---

## 5. Start-up

1. Reset. LOOPCFG holds the safe settings, `ready_pin_o` is low.
2. The firmware reads 2,052 bytes from flash address 0: the 2,048-byte
   weight image and a 4-byte checksum (section 8). On a checksum mismatch
   it retries, 3 tries in all; after that it sets WEIGHTS_FAULT,
   `fault_pin_o` and IRQST bit 1, and stops.
3. It reads the image's header (normalisation) and config block, and
   starts the SICU.
4. Cold start: it collects 32 S4 measurements, 320 s, before the first
   forecast. Advice stays safe and `ready_pin_o` low until then.
5. From the first forecast on, `ready_pin_o` is high and a new forecast is
   published every 10 s.

---

## 6. Each 10 s window

1. Re-check the whole weight SRAM against the load-time checksum. On a
   mismatch: write the safe loop settings, drop `ready_pin_o`, reload from
   flash, then continue (section 7).
2. Read the window's S4 and add it to the 32-entry history.
3. Normalise the history, `(S4 - mu) * (1/sd)` from the image header, and
   run the accelerator: 101,100 cycles, 3.3 ms.
4. Classify the three logits: SEVERE if `logit2 - max(logit0, logit1) >=
   margin`, else the larger of NOMINAL and DEGRADED. CONF =
   (winner - runner-up) >> shift, limited to 0-15. Margin and shift come
   from the image (defaults 0.25 and 6).
5. Publish: LOOPCFG first, then CLASS and CONF, which raises IRQST bit 0 on
   SEVERE. The order guarantees the host never reads stale loop settings on
   the interrupt.

---

## 7. Fail-safes

| Condition | What the host sees |
|---|---|
| `bypass_pin_i` high, or CTRL.BYPASS | CLASS 0, VALID 0, CONF 0, INDEX 0, safe LOOPCFG, `irq_o` low, `ready_pin_o` low; within 2 cycles of the pin (synchroniser) |
| Booting or cold start | Safe LOOPCFG, `ready_pin_o` low |
| Weight image will not load | WEIGHTS_FAULT, `fault_pin_o` high, IRQST bit 1; no forecasts |
| Weight SRAM corrupted while running | Safe LOOPCFG, then `ready_pin_o` low, until the image is reloaded and verified; the S4 history is kept |

---

## 8. Flash image

Bytes 0-2,047: 512 little-endian 32-bit words, two signed Q8.8 values per
word, even slot in the low half. Bytes 2,048-2,051: checksum, little-endian,
`c = rotl(c, 1) XOR word` over the 512 words starting from 0.

| Slots | Contents |
|---|---|
| 0-1 | Normalisation mean, features 0 and 1 |
| 2-3 | Reciprocal of normalisation std dev, features 0 and 1 |
| 4 | SEVERE probability threshold (informational; the firmware uses the margin in slot 994) |
| 5-991 | LSTM and head weights (`rtl/weights/WEIGHT_FORMAT.md`) |
| 992 | Config tag 0xC0F1 |
| 993 | Config version 1 |
| 994 | SEVERE logit margin, Q8.8 |
| 995 | Confidence shift, 0-15 |
| 996-998 | LOOPCFG for NOMINAL, DEGRADED, SEVERE |
| 999-1023 | Zero |

An image without the tag runs on the firmware's defaults (section 3,
section 6). Build images with `python/ml/export_weights.py`; change the
config of an existing image with `python/ml/config_block.py`.

---

## 9. Rev 1 limitations

- **CTRL.ENABLE and CTRL.BIST do nothing.** The firmware does not read the
  host control bits, so ENABLE is stored but ignored, and BIST_DONE /
  BIST_PASS never set. Either implement them in firmware before tape-out or
  document them as reserved.
- **sigma-phi is not computed.** INDEX[31:16] is always 0.
- **The UART is unused,** and its baud divisor assumes a 33 MHz clock
  (`CLK_FREQ_HZ` in `navic_sips_top.sv`) while the chip runs at 30.3 MHz,
  so 115,200 baud would come out about 8% slow, likely too far for a UART
  receiver. Fix `CLK_FREQ_HZ` before tape-out if the UART is to be used
  for bring-up.
- **Interface timing and loop codes** are placeholders until agreed with
  the receiver side (sections 2 and 3).
- **Pads and I/O** depend on the shuttle (section 1).
