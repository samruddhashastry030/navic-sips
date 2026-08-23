# SKY130 area budget (measured)

| Block            | Die area (um2) | Power (mW) | Status |
|------------------|----------------|------------|--------|
| uart_tx          | 5,081          | 0.29       | done   |
| navic_sips_regs  | (fill in)      |            | done   |
| spi_master       | 7,981          | 0.45       | done   |
| SICU             | TBD            |            | pending Track A |
| systolic array   | TBD            |            | pending Tracks B/C |
| CORDIC           | TBD            |            | pending |
| PicoRV32         | TBD            |            | pending |
| 2x 2KB SRAM      | ~570,000       |            | fixed (PDK macro) |

SRAM dominates by ~2 orders of magnitude. The floorplan is two macros
with logic placed around them, not the other way round.
