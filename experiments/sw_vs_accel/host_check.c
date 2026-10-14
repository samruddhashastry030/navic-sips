/* host_check.c -- fw/lstm_sw.c against the accelerator's 64 golden vectors,
 * compiled for the host. Every logit must match exactly, as the RTL must.
 *   cc -O2 -I fw -I <dir with lut_tables.h> -DLSTM_SW_WEIGHTS=wimg \
 *      experiments/sw_vs_accel/host_check.c -o host_check && ./host_check */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
int16_t wimg[1024];
#include "../../fw/lstm_sw.c"

int main(void)
{
    FILE *f = fopen("rtl/weights/weights.hex", "r");
    unsigned v; int i = 0;
    while (i < 512 && fscanf(f, "%x", &v) == 1) {
        wimg[2*i] = (int16_t)(v & 0xFFFF); wimg[2*i+1] = (int16_t)(v >> 16); i++;
    }
    fclose(f);
    f = fopen("rtl/weights/golden_vectors.hex", "r");
    char line[256]; int16_t x0[32], x1[32]; int t = 0, n = 0, bad = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned a, b, c, d;
        if (!strncmp(line, "//", 2) || line[0] == '\n') continue;
        if (!strncmp(line, "EXP", 3)) {
            sscanf(line + 3, "%x %x %x %x", &a, &b, &c, &d);
            int16_t g0, g1, g2;
            lstm_sw(x0, x1, &g0, &g1, &g2);
            if (g0 != (int16_t)a || g1 != (int16_t)b || g2 != (int16_t)c) {
                printf("vector %d: got %d %d %d expected %d %d %d\n", n,
                       g0, g1, g2, (int16_t)a, (int16_t)b, (int16_t)c); bad++;
            }
            n++; t = 0; continue;
        }
        sscanf(line, "%x %x", &a, &b);
        x0[t] = (int16_t)a; x1[t] = (int16_t)b; t++;
    }
    printf("%s: %d of %d golden vectors bit-exact\n", bad ? "FAIL" : "PASS", n - bad, n);
    return bad != 0;
}
