# SKY130 area budget (measured)

| Block            | Die area (um2) | Power (mW) | Status |
|------------------|----------------|------------|--------|
| uart_tx          | 5,081          | 0.29       | done   |
| navic_sips_regs  | 24,921         | 0.002      | done   |
| spi_master       | 7,981          | 0.45       | done   |
| SICU             | 177,705        | 0.005      | done, 30 ns |
| LSTM accel (seq) | TBD            |            | RTL verified, not hardened |
| systolic array   | TBD            |            | pending Tracks B/C |
| CORDIC           | TBD            |            | pending |
| PicoRV32         | TBD            |            | pending |
| weight SRAM 2 KB | 284,540        |            | fixed (PDK macro) |
| event SRAM 1 KB  | 190,712        |            | fixed (PDK macro) |

Measured macro total is 475,251 um2 (683.1x416.54 + 479.78x397.5), not the
~570,000 previously estimated. On the 1800x1100 um trial floorplan that is
24% of the die.

SRAM still dominates the logic by an order of magnitude, so the floorplan is
two macros with logic placed around them, not the other way round.

Timing: every block except the SICU closes at 10 ns. The SICU needs 30 ns
because of the sequential divider's 64-bit carry chain, and at 30 ns it
passes tt (+14.2 ns) and ff (+19.5 ns) with ss marginally short at -0.70 ns.
Since they share one clock domain this currently sets the SoC to 33 MHz.
Nothing in the design is throughput-bound -- the SICU produces one result per
10 s and the LSTM needs ~98,000 cycles per inference -- so 33 MHz is ample,
but pipelining the divider would recover 100 MHz if wanted.

Power figures come from the flow's estimate at each block's own clock, so
they are not directly comparable across rows.
