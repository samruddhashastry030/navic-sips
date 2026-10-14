/* bench.c -- inference cost on the real chip RTL, accelerator vs. software.
 *
 * Runs the first NV golden vectors (already normalised) through either the
 * accelerator (default) or fw/lstm_sw.c (-DSW_LSTM), timing each with the
 * CPU's cycle counter, and reports cycles and logits to unmapped SYS offsets
 * that tb_bench.sv watches. Weights are preloaded into the weight SRAM by the
 * testbench, so no SPI boot -- this measures inference and nothing else.
 */
#include <stdint.h>
#include "sips.h"
#include "bench_vectors.h"      /* NV, vec_x0[NV][32], vec_x1[NV][32] */

void lstm_sw(const int16_t *x0, const int16_t *x1,
             int16_t *l0, int16_t *l1, int16_t *l2);

static inline uint32_t cycles(void)
{
    uint32_t c;
    __asm__ volatile ("rdcycle %0" : "=r"(c));
    return c;
}

static void run_hw(const int16_t *x0, const int16_t *x1,
                   int16_t *l0, int16_t *l1, int16_t *l2)
{
    ACCEL_CTRL = 1u;
    for (uint32_t t = 0; t < 32; t++) {
        while (ACCEL_STATUS & ACCEL_ST_PENDING) ;
        ACCEL_FEAT = ((uint32_t)(uint16_t)x1[t] << 16) | (uint16_t)x0[t];
    }
    while (!(ACCEL_STATUS & ACCEL_ST_DONE)) ;
    uint32_t a = ACCEL_LOGIT01, b = ACCEL_LOGIT2;
    *l0 = (int16_t)(a & 0xFFFFu); *l1 = (int16_t)(a >> 16); *l2 = (int16_t)b;
}

int main(void)
{
    for (uint32_t v = 0; v < NV; v++) {
        int16_t l0, l1, l2;
        uint32_t c0 = cycles();
#ifdef SW_LSTM
        lstm_sw(vec_x0[v], vec_x1[v], &l0, &l1, &l2);
#else
        run_hw(vec_x0[v], vec_x1[v], &l0, &l1, &l2);
#endif
        uint32_t c1 = cycles();
        REG32(SYS_BASE + 0x20) = c1 - c0;
        REG32(SYS_BASE + 0x24) = ((uint32_t)(uint16_t)l1 << 16) | (uint16_t)l0;
        REG32(SYS_BASE + 0x28) = (v << 16) | (uint16_t)l2;
    }
    REG32(SYS_BASE + 0x2C) = 1u;
    for (;;) ;
}
