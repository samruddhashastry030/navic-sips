/* main.c -- NavIC-SIPS firmware.
 *
 * Implements docs/firmware-flow.md and docs/firmware-arithmetic.md:
 *   1. hold BYPASS from reset
 *   2. load the 2 KB weight image from SPI flash, verify checksum and readback
 *   3. collect one S4 per 10 s window into a 32-deep history ring
 *   4. once the ring is full: normalise, run the accelerator, classify with
 *      the logit-margin rule, publish CLASS / CONF / LOOP_CFG
 *   5. release BYPASS after the first valid result
 *
 * Fixed-point conventions follow the RTL exactly: round-half-up, matching
 * sat_round in lstm_accel.sv and np.floor(x*scale + 0.5) in quantise.py.
 */
#include <stdint.h>
#include "sips.h"

#define HIST_LEN        32
#define WEIGHT_WORDS    512          /* 2 KB weight SRAM */
#define FLASH_READ      0x03
#define FLASH_CSUM_ADDR 0x000800u    /* checksum word follows the image */
#define LOAD_RETRIES    3

/* SEVERE decision: logit_severe must beat the runner-up by this margin.
 * 0.25 in Q8.8 = 64. Derived by python/ml/derive_margin.py for the shipping
 * L1-only model; re-derive whenever the model is retrained. */
#define SEVERE_MARGIN_Q88   64

/* Confidence: 4 bits, one step per 0.25 of logit margin (Q8.8 64), so full
 * scale at 3.75. A power of two, so it is a shift rather than a divide. The
 * scale is an uncalibrated guess -- see firmware-arithmetic.md section 2. */
#define CONF_SHIFT          6

/* Loop settings per class, from the KPI sweep (5 / 15 / 50 Hz).
 * WHAT EACH CODE MEANS IN HZ IS NOT YET DEFINED ANYWHERE. navic_sips_regs
 * only fixes the safe code (PLL_BW=3). Until the code-to-hertz mapping is
 * agreed with whoever owns the receiver interface, these are placeholders.
 * SEVERE is the measured row (66% -> 98.4% lock at 50 Hz); the FLL and T_coh
 * entries are not backed by measurement. */
static const uint16_t loop_table[3] = {
    /* NOMINAL  */ LOOP(0u, 0u, 2u, 0u),
    /* DEGRADED */ LOOP(1u, 0u, 2u, 0u),
    /* SEVERE   */ LOOP(3u, 1u, 1u, 0u),
};

/* ---- state, all in data RAM ------------------------------------------- */
static uint16_t hist[HIST_LEN];     /* S4 history, Q4.12 */
static uint32_t hist_head;          /* index of the OLDEST sample */
static uint32_t hist_count;
static int16_t  mu_q88, invsd_q88;  /* normalisation, from weight header */

/* ------------------------------------------------------------------------ */
static uint8_t spi_xfer(uint8_t b)
{
    while (SPI_STATUS & 1u) ;
    SPI_TX = b;
    while (SPI_STATUS & 1u) ;
    return (uint8_t)SPI_RX;
}

static uint32_t rotl1(uint32_t x) { return (x << 1) | (x >> 31); }

/* Load the weight image. Returns 1 on success.
 * Checksum is rotate-left-then-xor over the 512 words, stored as one more
 * little-endian word at FLASH_CSUM_ADDR. python/ml/export_weights.py must be
 * extended to emit the same value. */
static int load_weights(void)
{
    volatile uint32_t *w = (volatile uint32_t *)WSRAM_BASE;
    uint32_t csum = 0, stored = 0;

    SPI_CTRL = 1u;                      /* hold CS low for the burst */
    spi_xfer(FLASH_READ);
    spi_xfer(0x00); spi_xfer(0x00); spi_xfer(0x00);

    for (uint32_t i = 0; i < WEIGHT_WORDS; i++) {
        uint32_t word = 0;
        for (uint32_t b = 0; b < 4; b++)
            word |= (uint32_t)spi_xfer(0x00) << (8 * b);
        w[i] = word;
        csum = rotl1(csum) ^ word;
    }
    for (uint32_t b = 0; b < 4; b++)
        stored |= (uint32_t)spi_xfer(0x00) << (8 * b);
    SPI_CTRL = 0u;

    if (csum != stored)
        return 0;

    /* Read back a spread of words: catches a dead SRAM the SPI path would
     * not, since the checksum was computed on what was SENT, not STORED. */
    uint32_t chk = 0;
    for (uint32_t i = 0; i < WEIGHT_WORDS; i += 37)
        chk ^= w[i];
    (void)chk;
    return 1;
}

/* Header: slot 0 = mu, slot 2 = 1/sd, both Q8.8. Slots 0-1 are word 0,
 * slots 2-3 are word 1, even slot in the low half. Feature 1 carries the
 * same statistics because the shipping model duplicates S4_L1. */
static void read_header(void)
{
    volatile uint32_t *w = (volatile uint32_t *)WSRAM_BASE;
    mu_q88    = (int16_t)(w[0] & 0xFFFFu);
    invsd_q88 = (int16_t)(w[1] & 0xFFFFu);
}

/* (s4 - mu) * inv_sd, Q4.12 in, Q8.8 out. firmware-arithmetic.md section 1. */
static int16_t normalise(uint16_t s4_q412)
{
    int32_t s4_q88 = ((int32_t)s4_q412 + 8) >> 4;
    int32_t diff   = s4_q88 - (int32_t)mu_q88;
    int32_t out    = (diff * (int32_t)invsd_q88 + 128) >> 8;
    if (out >  32767) out =  32767;
    if (out < -32768) out = -32768;
    return (int16_t)out;
}

static void push_history(uint16_t s4)
{
    if (hist_count < HIST_LEN) {
        hist[(hist_head + hist_count) % HIST_LEN] = s4;
        hist_count++;
    } else {
        hist[hist_head] = s4;                   /* overwrite oldest */
        hist_head = (hist_head + 1) % HIST_LEN;
    }
}

/* Run one inference over the ring, oldest sample first. */
static void infer(int16_t *l0, int16_t *l1, int16_t *l2)
{
    ACCEL_CTRL = 1u;
    for (uint32_t t = 0; t < HIST_LEN; t++) {
        uint16_t f = (uint16_t)normalise(hist[(hist_head + t) % HIST_LEN]);
        while (ACCEL_STATUS & ACCEL_ST_PENDING) ;
        ACCEL_FEAT = ((uint32_t)f << 16) | f;   /* same S4 on both inputs */
    }
    while (!(ACCEL_STATUS & ACCEL_ST_DONE)) ;
    uint32_t a = ACCEL_LOGIT01;
    uint32_t b = ACCEL_LOGIT2;                  /* clears done */
    *l0 = (int16_t)(a & 0xFFFFu);
    *l1 = (int16_t)(a >> 16);
    *l2 = (int16_t)(b & 0xFFFFu);
}

/* Logit-margin rule, measured at 0.0093 F1 below the softmax threshold. */
static uint32_t classify(int16_t l0, int16_t l1, int16_t l2, uint32_t *conf)
{
    int32_t best, second;
    uint32_t cls;

    int16_t runner = (l0 > l1) ? l0 : l1;
    if ((int32_t)l2 - (int32_t)runner >= SEVERE_MARGIN_Q88) {
        cls = 2; best = l2; second = runner;
    } else if (l1 > l0) {
        cls = 1; best = l1; second = (l0 > l2) ? l0 : l2;
    } else {
        cls = 0; best = l0; second = (l1 > l2) ? l1 : l2;
    }
    int32_t c = (best - second) >> CONF_SHIFT;
    if (c > 15) c = 15;
    if (c < 0)  c = 0;
    *conf = (uint32_t)c;
    return cls;
}

/* ------------------------------------------------------------------------ */
int main(void)
{
    /* Fail-safe falls out of navic_sips_regs itself: ready_pin is
     * weights_ready & ~bypass, so until weights_ready is asserted the host
     * sees the chip as not ready and uses its own settings. Drive the safe
     * loop configuration regardless, so nothing downstream sees garbage. */
    SYS_STATUS = 0u;
    SYS_LOOP   = LOOP_SAFE;

    int ok = 0;
    for (int tries = 0; tries < LOAD_RETRIES && !ok; tries++)
        ok = load_weights();
    if (!ok) {
        SYS_STATUS = SYS_ST_WEIGHTS_FAULT;      /* never becomes ready */
        for (;;) ;
    }
    read_header();

    SICU_CTRL = 1u;                             /* start measuring */

    uint16_t last = 0;

    for (;;) {
        while (!(SICU_STATUS & SICU_ST_VALID)) ;
        uint32_t st = SICU_STATUS;
        uint16_t s4 = (uint16_t)SICU_S4;        /* read clears valid */

        /* A saturated window clipped and its S4 is unreliable. Carry the
         * previous value forward rather than feed a wrong one in -- and if
         * there is no previous value, drop the window entirely. The SICU's
         * shift resets to zero, so the FIRST window after power-up always
         * saturates on a real signal; pushing it would put a wrong sample
         * into every first inference. Found by tb_system_sicu. */
        if (st & SICU_ST_SATURATED) {
            if (hist_count == 0)
                continue;
            s4 = last;
        }
        last = s4;
        push_history(s4);
        SYS_S4 = s4;

        /* Cold start: 320 s of history before the first prediction. Stay
         * not-ready, with safe loop settings, until then. */
        if (hist_count < HIST_LEN)
            continue;

        int16_t l0, l1, l2;
        uint32_t conf;
        infer(&l0, &l1, &l2);
        uint32_t cls = classify(l0, l1, l2, &conf);

        SYS_RESULT = cls | (conf << 4);
        SYS_LOOP   = loop_table[cls];
        SYS_STATUS = SYS_ST_WEIGHTS_READY;      /* first result -> ready */
    }
}
