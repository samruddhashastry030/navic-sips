/* sips.h -- NavIC-SIPS memory map and register layout.
 *
 * Must match docs/memory-map.md and the RTL bus decoder exactly.
 *
 * VERIFY BEFORE TRUSTING: the system register block (SYS_*) and SPI offsets
 * below are this file's assumption. navic_sips_regs.sv defines its own
 * layout, and the SPI bus adapter does not exist yet. Check both against the
 * RTL and correct here -- the addresses are the only thing that changes.
 */
#ifndef SIPS_H
#define SIPS_H

#include <stdint.h>

#define REG32(addr)  (*(volatile uint32_t *)(addr))

/* ---- regions, decoded on addr[31:28] ---------------------------------- */
#define ROM_BASE     0x00000000u
#define RAM_BASE     0x10000000u   /* event SRAM, 1 KB, CPU data RAM */
#define WSRAM_BASE   0x20000000u   /* weight SRAM port 0, 2 KB */
#define SPI_BASE     0x40000000u
#define UART_BASE    0x50000000u
#define SICU_BASE    0x60000000u
#define ACCEL_BASE   0x70000000u

/* ---- SICU (docs/memory-map.md section 3) ------------------------------ */
#define SICU_CTRL    REG32(SICU_BASE + 0x00)
#define SICU_STATUS  REG32(SICU_BASE + 0x04)
#define SICU_S4      REG32(SICU_BASE + 0x08)   /* Q4.12; read clears valid */
#define SICU_SHIFT   REG32(SICU_BASE + 0x0C)
#define SICU_ST_VALID      (1u << 0)
#define SICU_ST_SATURATED  (1u << 1)

/* ---- LSTM accelerator -------------------------------------------------- */
#define ACCEL_CTRL    REG32(ACCEL_BASE + 0x00)
#define ACCEL_STATUS  REG32(ACCEL_BASE + 0x04)
#define ACCEL_FEAT    REG32(ACCEL_BASE + 0x08)
#define ACCEL_LOGIT01 REG32(ACCEL_BASE + 0x0C)
#define ACCEL_LOGIT2  REG32(ACCEL_BASE + 0x10)  /* read clears done */
#define ACCEL_ST_BUSY     (1u << 0)
#define ACCEL_ST_PENDING  (1u << 1)
#define ACCEL_ST_DONE     (1u << 2)

/* ---- SPI master (ASSUMED layout -- bus adapter not yet written) -------- */
#define SPI_TX       REG32(SPI_BASE + 0x00)  /* write starts one byte */
#define SPI_RX       REG32(SPI_BASE + 0x04)
#define SPI_STATUS   REG32(SPI_BASE + 0x08)  /* bit0 = busy */
#define SPI_CTRL     REG32(SPI_BASE + 0x0C)  /* bit0 = hold chip-select low */

/* ---- system register block (CPU side) -------------------------------
 * NOT navic_sips_regs. That block's bus faces the external host and its
 * STATUS / INDEX / LOOPCFG are read-only from there; they are driven through
 * input ports. This CPU-side block holds the values that feed those ports.
 * It does not exist in RTL yet -- the bus decoder work creates it, and it
 * must unpack these fields onto navic_sips_regs' inputs exactly as below. */
#define SYS_BASE       0x30000000u
#define SYS_STATUS     REG32(SYS_BASE + 0x00)  /* W: feeds weights/BIST inputs */
#define SYS_RESULT     REG32(SYS_BASE + 0x04)  /* W: [1:0] class, [7:4] conf */
#define SYS_LOOP       REG32(SYS_BASE + 0x08)  /* W: loop settings, packed below */
#define SYS_S4         REG32(SYS_BASE + 0x0C)  /* W: [15:0] S4 -> host INDEX */
#define SYS_HOSTCTRL   REG32(SYS_BASE + 0x10)  /* R: host's CTRL outputs */

#define SYS_ST_WEIGHTS_READY (1u << 0)  /* -> weights_ready_i; gates ready_pin */
#define SYS_ST_WEIGHTS_FAULT (1u << 1)  /* -> weights_fault_i */
#define SYS_ST_BIST_DONE     (1u << 2)
#define SYS_ST_BIST_PASS     (1u << 3)

/* SYS_LOOP packing: [2:0] PLL bandwidth code, [3] FLL enable,
 * [6:4] coherent-integration code, [8:7] band preference. */
#define LOOP(pll, fll, tcoh, band) \
    ((pll) | ((fll) << 3) | ((tcoh) << 4) | ((band) << 7))

/* The safe settings navic_sips_regs itself uses in BYPASS
 * (SAFE_PLL_BW=3, SAFE_FLL_EN=0, SAFE_T_COH=3, SAFE_BAND_PREF=0). */
#define LOOP_SAFE  LOOP(3u, 0u, 3u, 0u)

/* ---- UART -------------------------------------------------------------- */
#define UART_TX      REG32(UART_BASE + 0x00)
#define UART_STATUS  REG32(UART_BASE + 0x04)  /* bit0 = busy */

#endif
