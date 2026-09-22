# NavIC-SIPS memory map

The contract between the RTL and the firmware. Every address here has to
match in both, so it is fixed on paper before the bus decoder is written.

---

## 0. A gap this surfaced: there is no program memory

PicoRV32 needs somewhere to fetch instructions from and somewhere to keep
its stack. The chip currently has two memories, and both are spoken for:

| Macro | Size | Current use |
|---|---|---|
| weight SRAM, 2 KB, 512 x 32 | 2,048 B | 992 slots of weights, 32 spare |
| event SRAM, 1 KB, 256 x 32 | 1,024 B | nominally an event log |

The weight SRAM is 97% full and cannot hold code. That leaves nowhere for
firmware to run from.

**Proposed resolution:**

- **Firmware runs from a boot ROM**, synthesised as logic. The firmware's
  job is small — boot, load weights over SPI, verify, then a loop — so it
  should fit in 1-2 KB of compressed RV32IMC.
- **The event SRAM becomes the CPU's data RAM.** Stack, the 32-deep S4
  history ring (64 bytes), and working variables. 1 KB is ample for this
  workload. An event log, if still wanted, can use a slice of it.

The ROM's area depends on the firmware's size, and the firmware has not
been written. So the order is: write the firmware, measure it, then size the
ROM. A 2 KB ROM as synthesised logic is roughly 16,000 bits and could be
tens of thousands of um2 — worth knowing before committing.

---

## 1. Address map

Decode on the top nibble of the address. Cheap, and leaves each region far
more space than it needs.

| Base | Size used | Target | Access |
|---|---|---|---|
| `0x0000_0000` | ~2 KB | Boot ROM | read, instruction fetch |
| `0x1000_0000` | 1 KB | Data RAM (event SRAM, port 0) | read / write |
| `0x2000_0000` | 2 KB | Weight SRAM, port 0 | read / write, boot only |
| `0x3000_0000` | 32 B | Host register block (`navic_sips_regs`) | read / write |
| `0x4000_0000` | 16 B | SPI master | read / write |
| `0x5000_0000` | 8 B | UART | write |
| `0x6000_0000` | 16 B | SICU | read, one control write |
| `0x7000_0000` | 32 B | LSTM accelerator | read / write |

PicoRV32 parameters that follow from this:

- `PROGADDR_RESET = 32'h0000_0000` — boot from ROM
- `STACKADDR = 32'h1000_0400` — top of data RAM
- `PROGADDR_IRQ = 32'h0000_0010` — interrupt handler in ROM

Any access outside these regions should return zero and complete, rather
than hang the bus. A hung bus is the hardest failure to debug on silicon.

---

## 2. SRAM addressing

PicoRV32 issues byte addresses and a 4-bit write strobe. The SKY130 macros
are word-addressed with a 4-bit byte mask. These map directly:

```
macro addr   = mem_addr[N+1:2]      // drop the byte offset
macro wmask  = mem_wstrb            // one bit per byte
macro web    = ~|mem_wstrb          // any strobe set means write
```

For the 2 KB weight SRAM `N = 9`, so `mem_addr[10:2]`. For the 1 KB data RAM
`N = 8`, so `mem_addr[9:2]`.

**Latency matters.** The macros register their output: address sampled at
one edge, data valid after the next. So a read to either SRAM must assert
`mem_ready` two cycles after `mem_valid`, not one. This is the same
two-cycle latency the accelerator already handles internally, and getting
it wrong gives the CPU the previous word's data.

---

## 3. Peripheral registers

### SICU — base `0x6000_0000`

The SICU's *input* — prompt I/Q at 50 Hz — comes from the tracking loop
directly, not over the bus. The CPU only reads results.

| Offset | Name | Bits | Access | Meaning |
|---|---|---|---|---|
| `0x00` | CTRL | [0] | R/W | enable |
| `0x04` | STATUS | [0] | R | `s4_valid` — a new window is ready (sticky) |
| | | [1] | R | `saturated` — that window clipped |
| | | [2] | R | `busy` |
| `0x08` | S4 | [15:0] | R | S4, Q4.12. **Reading clears `s4_valid`** |
| `0x0C` | SHIFT | [4:0] | R | intensity shift used, for telemetry |

`s4_valid` is sticky because the SICU pulses `s4_valid_o` for one cycle,
and the CPU may not be looking. Latching it and clearing on read of `S4`
means a result is never missed and never read twice.

### LSTM accelerator — base `0x7000_0000`

The accelerator consumes 32 timesteps through a ready/valid handshake. The
CPU drives that handshake through two registers.

| Offset | Name | Bits | Access | Meaning |
|---|---|---|---|---|
| `0x00` | CTRL | [0] | W | write 1 to pulse `start` |
| `0x04` | STATUS | [0] | R | `busy` |
| | | [1] | R | `feat_pending` — last FEAT write not yet taken |
| | | [2] | R | `done` — result ready (sticky) |
| `0x08` | FEAT | [15:0] | W | timestep feature 0, Q8.8 |
| | | [31:16] | W | timestep feature 1, Q8.8 |
| `0x0C` | LOGIT01 | [15:0] | R | logit 0 (NOMINAL) |
| | | [31:16] | R | logit 1 (DEGRADED) |
| `0x10` | LOGIT2 | [15:0] | R | logit 2 (SEVERE). **Reading clears `done`** |
| | | [17:16] | R | argmax class |

A write to FEAT sets `feat_pending`, which drives the accelerator's
`in_valid`. When the accelerator accepts, `feat_pending` clears. Firmware
waits for `feat_pending == 0` before the next write:

```c
ACCEL_CTRL = 1;                               // start
for (int t = 0; t < 32; t++) {
    int16_t f = normalise(history[(head + t) % 32], mu, invsd);
    while (ACCEL_STATUS & FEAT_PENDING) ;     // wait for last one to go
    ACCEL_FEAT = ((uint32_t)(uint16_t)f << 16) | (uint16_t)f;  // same S4, both
}
while (!(ACCEL_STATUS & DONE)) ;
```

Feature 0 and feature 1 carry the same value, because the shipping model is
the L1-only one trained with the channel duplicated.

The accelerator spends about 3,000 cycles computing each timestep, so the
CPU spends almost all of inference polling. That is fine at this workload,
but it is the obvious place to add an interrupt later.

---

## 4. Bus decoder behaviour

The decoder sits between PicoRV32's native interface and every target.

```
mem_valid, mem_addr, mem_wdata, mem_wstrb   ->   decoder   ->   targets
mem_ready, mem_rdata                        <-   decoder   <-   targets
```

What it has to get right:

**Select on `mem_addr[31:28]`.** One target per region.

**Per-target latency.** ROM and registers can complete in one cycle. The
two SRAMs need two. The decoder asserts `mem_ready` when the selected
target's data is actually valid, not on a fixed schedule.

**Return data from the right target.** `mem_rdata` is muxed by the region
that was selected *when the access began*, registered, so a late-arriving
SRAM result is not steered by an address that has since changed.

**Never hang.** Unmapped regions complete immediately with zero data.

**Only strobe on write.** Registers and SRAMs see a write only when
`mem_wstrb != 0`; reads leave them untouched. Sticky flags that clear on
read clear only on a genuine read of that address.

---

## 5. What is still open

**ROM size.** Depends on the firmware. Write it, compile it, measure it.

**Event log.** If the event SRAM becomes data RAM, is a log still wanted,
and how much of the 1 KB can it have?

**Interrupts.** Polling works but wastes the CPU. PicoRV32 has an IRQ input;
wiring the SICU's `s4_valid` and the accelerator's `done` to it would let
the CPU sleep between windows, which matters more for power than anything
else in this design — the CPU is idle over 99.9% of the time.
