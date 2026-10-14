/* lstm_sw.c -- the LSTM run in software on the CPU, no accelerator.
 *
 * Built only with -DSW_LSTM, for the "is the accelerator worth it?"
 * comparison in experiments/sw_vs_accel/. It must produce BIT-IDENTICAL
 * logits to rtl/lstm_accel.sv, so it copies that block's arithmetic exactly:
 *
 *   - Q8.8 operands, products summed at full width (int64 here, 40 bits in
 *     the RTL), rounded once with sat_round = round-half-up then saturate
 *   - gate order i, f, g, o; g through tanh, the rest through sigmoid
 *   - layer 0 sees the two input features and its own PREVIOUS hidden state;
 *     layer 1 sees layer 0's CURRENT hidden state and its own previous one
 *   - c_new = sat_round(f*c + i*g), h = sat_round(o * tanh(c_new))
 *   - head: logit = sat_round(bias<<8 + sum w*h1)
 *
 * Weights are read straight from the weight SRAM through the CPU's port,
 * exactly where the accelerator reads them. The two 256-entry gate LUTs
 * live in ROM (lut_tables.h) -- 1 KB the accelerator keeps inside itself.
 */
#include <stdint.h>
#include "sips.h"
#include "lut_tables.h"

#define N_FEAT   2
#define HIDDEN   8
#define G        (4 * HIDDEN)
#define SEQ_LEN  32
#define N_CLASS  3

/* Slot bases, rtl/weights/WEIGHT_FORMAT.md */
#define WIH0_B   5
#define WHH0_B   (WIH0_B + G * N_FEAT)
#define BIH0_B   (WHH0_B + G * HIDDEN)
#define BHH0_B   (BIH0_B + G)
#define WIH1_B   (BHH0_B + G)
#define WHH1_B   (WIH1_B + G * HIDDEN)
#define BIH1_B   (WHH1_B + G * HIDDEN)
#define BHH1_B   (BIH1_B + G)
#define HEDW_B   (BHH1_B + G)
#define HEDB_B   (HEDW_B + N_CLASS * HIDDEN)

/* Accumulator width. The RTL sums at 40 bits; int64 is the safe software
 * equivalent. -DLSTM_ACC32 uses int32, which is still bit-exact whenever
 * every weight and bias satisfies |w| < 3640 (Q8.8, i.e. 14.2): the widest
 * sum is 16 products of |w| * 32768 plus two biases << 8, under 2^31; the
 * cell update multiplies by gate values, which the LUTs cap at 1.0 (256).
 * The shipping image peaks at 1074 (4.2). lstm_sw_acc32_ok() checks an image. */
#ifdef LSTM_ACC32
typedef int32_t acc_t;
#else
typedef int64_t acc_t;
#endif

static inline int16_t sat_round(acc_t a)
{
    acc_t r = (a + 128) >> 8;
    if (r >  32767) return  32767;
    if (r < -32768) return -32768;
    return (int16_t)r;
}

static inline uint32_t lut_index(int16_t x)
{
    int32_t xc = x;
    if (xc >  2048) xc =  2048;
    if (xc < -2048) xc = -2048;
    int32_t num = ((((xc + 2048) << 8) - (xc + 2048)) + 2048) >> 12;
    if (num > 255) num = 255;
    if (num < 0)   num = 0;
    return (uint32_t)num;
}

/* x0, x1: SEQ_LEN normalised Q8.8 samples per feature, oldest first. The
 * firmware passes the same array twice (both features carry S4_L1). */
#ifndef LSTM_SW_WEIGHTS
#define LSTM_SW_WEIGHTS ((const int16_t *)WSRAM_BASE)
#endif

/* 1 if the loaded image keeps the int32 accumulator exact (see acc_t). */
int lstm_sw_acc32_ok(void)
{
    const int16_t *w = LSTM_SW_WEIGHTS;
    for (int s = WIH0_B; s < HEDB_B + N_CLASS; s++)
        if (w[s] >= 3640 || w[s] <= -3640) return 0;
    return 1;
}

void lstm_sw(const int16_t *x0, const int16_t *x1,
             int16_t *l0, int16_t *l1, int16_t *l2)
{
    const int16_t *w = LSTM_SW_WEIGHTS;
    int16_t h[2][HIDDEN], hp[2][HIDDEN], c[2][HIDDEN];
    int16_t gate[4];

    for (int l = 0; l < 2; l++)
        for (int u = 0; u < HIDDEN; u++)
            h[l][u] = hp[l][u] = c[l][u] = 0;

    for (int t = 0; t < SEQ_LEN; t++) {
        for (int l = 0; l < 2; l++)
            for (int u = 0; u < HIDDEN; u++)
                hp[l][u] = h[l][u];

        for (int l = 0; l < 2; l++) {
            const int in_w = l ? HIDDEN : N_FEAT;
            const int wih  = l ? WIH1_B : WIH0_B;
            const int whh  = l ? WHH1_B : WHH0_B;
            const int bih  = l ? BIH1_B : BIH0_B;
            const int bhh  = l ? BHH1_B : BHH0_B;

            for (int u = 0; u < HIDDEN; u++) {
                for (int gs = 0; gs < 4; gs++) {
                    const int row = gs * HIDDEN + u;
                    acc_t acc = ((acc_t)w[bih + row] << 8)
                              + ((acc_t)w[bhh + row] << 8);
                    const int16_t *wi = &w[wih + row * in_w];
                    for (int k = 0; k < in_w; k++) {
                        int16_t op = l ? h[0][k] : (k ? x1[t] : x0[t]);
                        acc += (int32_t)wi[k] * (int32_t)op;
                    }
                    const int16_t *wh = &w[whh + row * HIDDEN];
                    for (int k = 0; k < HIDDEN; k++)
                        acc += (int32_t)wh[k] * (int32_t)hp[l][k];

                    uint32_t ix = lut_index(sat_round(acc));
                    gate[gs] = (gs == 2) ? lut_tanh[ix] : lut_sigmoid[ix];
                }
                acc_t cs = (acc_t)((int32_t)gate[1] * (int32_t)c[l][u])
                         + (acc_t)((int32_t)gate[0] * (int32_t)gate[2]);
                int16_t cn = sat_round(cs);
                int16_t tc = lut_tanh[lut_index(cn)];
                c[l][u] = cn;
                h[l][u] = sat_round((int32_t)gate[3] * (int32_t)tc);
            }
        }
    }

    int16_t lg[N_CLASS];
    for (int k = 0; k < N_CLASS; k++) {
        acc_t acc = (acc_t)w[HEDB_B + k] << 8;
        for (int j = 0; j < HIDDEN; j++)
            acc += (int32_t)w[HEDW_B + k * HIDDEN + j] * (int32_t)h[1][j];
        lg[k] = sat_round(acc);
    }
    *l0 = lg[0]; *l1 = lg[1]; *l2 = lg[2];
}
