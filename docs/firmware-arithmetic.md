# NavIC-SIPS firmware arithmetic

Every fixed-point conversion the firmware performs, with shift counts made
explicit. This exists because unspecified arithmetic is where the bugs have
been: the accelerator's Newton-Raphson step was 4096x wrong from one missing
shift, and the golden vectors were off by 19-66 LSBs from a rounding
convention nobody had written down.

Formats in play:

| Value | Format | Range | LSB | Source |
|---|---|---|---|---|
| SICU S4 output | Q4.12 unsigned | 0 .. 16 | 0.000244 | `sicu.s4_o` |
| Accelerator input | Q8.8 signed | -128 .. 128 | 0.003906 | `lstm_accel.in_feat*_i` |
| Header mu | Q8.8 signed | | 0.003906 | weight slots 0-1 |
| Header 1/sd | Q8.8 signed | | 0.003906 | weight slots 2-3 |
| Header threshold | Q8.8 signed | | 0.003906 | weight slot 4 |
| Accelerator logits | Q8.8 signed | | 0.003906 | `lstm_accel.logit*_o` |

---

## 1. Normalisation: SICU output to accelerator input

The model wants `(s4 - mu) * inv_sd` as Q8.8. The inputs arrive in two
different formats, so the alignment has to be deliberate.

```c
/* s4_q412  : uint16, Q4.12, from sicu.s4_o
 * mu_q88   : int16,  Q8.8,  weight slot 0
 * invsd_q88: int16,  Q8.8,  weight slot 2
 * returns  : int16,  Q8.8
 */
int16_t normalise(uint16_t s4_q412, int16_t mu_q88, int16_t invsd_q88)
{
    /* Q4.12 -> Q8.8 : drop four fractional bits, rounding half-up to match
     * the convention in lstm_accel.sv's sat_round. */
    int32_t s4_q88 = ((int32_t)s4_q412 + 8) >> 4;

    /* Both operands now Q8.8, so the difference is Q8.8. */
    int32_t diff_q88 = s4_q88 - (int32_t)mu_q88;

    /* Q8.8 * Q8.8 = Q16.16. Shift back to Q8.8, again rounding half-up. */
    int32_t prod_q1616 = diff_q88 * (int32_t)invsd_q88;
    int32_t out_q88    = (prod_q1616 + 128) >> 8;

    /* Saturate. The accelerator's inputs are int16. */
    if (out_q88 >  32767) out_q88 =  32767;
    if (out_q88 < -32768) out_q88 = -32768;
    return (int16_t)out_q88;
}
```

Three things worth being explicit about:

**Rounding is half-up, not half-to-even.** `(x + half) >> shift`. This
matches `sat_round` in `lstm_accel.sv` and the `np.floor(x*scale + 0.5)` in
`quantise.py`. Getting this wrong cost a day of debugging on the
accelerator; it will cost the same here.

**The Q4.12 to Q8.8 step loses four bits of S4 precision.** S4's LSB goes
from 0.000244 to 0.003906. Against a SICU that matches CDAAC to a median of
0.006, that loss is immaterial — the quantisation is already finer than the
measurement agrees.

**Both features use the same S4** if the single-feature recommendation is
adopted. Call `normalise` twice with slots 0/2 and 1/3 respectively, or once
if the model is retrained with `N_FEAT=1`.

---

## 2. Confidence: argmax margin to 4 bits

`CONF` in the register block is 4 bits. The natural measure is how far the
winning logit sits above the runner-up.

```c
uint8_t confidence(int16_t l0, int16_t l1, int16_t l2)
{
    int16_t a = l0, b = l1, c = l2, t;
    if (a < b) { t = a; a = b; b = t; }
    if (b < c) { t = b; b = c; c = t; }
    if (a < b) { t = a; a = b; b = t; }
    /* a is largest, b second. Margin is Q8.8. */
    int32_t margin_q88 = (int32_t)a - (int32_t)b;

    /* Map to 0..15. A margin of 4.0 in Q8.8 is 1024; treat that as full
     * confidence. Scale: 1024 / 15 ~= 68 per step. */
    int32_t conf = margin_q88 / 68;
    if (conf > 15) conf = 15;
    if (conf < 0)  conf = 0;
    return (uint8_t)conf;
}
```

The full-confidence margin of 4.0 is a guess and should be calibrated
against the distribution of margins in `sim/lstm_l1only/` before tape-out.
It is firmware, so it stays tunable.

---

## 3. Threshold application

Weight slot 4 holds the SEVERE decision threshold as Q8.8 — 0.512 for the
shipping model, stored as 0x0083.

The accelerator emits raw logits and a plain argmax. The threshold applies
to the softmax probability of the SEVERE class, which the firmware would
have to compute — an exponential per class, which PicoRV32 would do slowly.

**Cheaper equivalent, measured.** `python/ml/derive_margin.py` swept a
logit-margin rule against the tuned softmax threshold on the validation
split. The best margin is **0.25**, which agrees with the tuned rule on
99.92% of samples.

On the test split: softmax threshold 0.5913, logit margin 0.5820, plain
argmax 0.5715. So the margin rule costs 0.0093 and recovers half the gap
for a subtraction and a comparison.

```c
/* margin 0.25 in Q8.8 = 64 = 0x0040 */
#define SEVERE_MARGIN_Q88  64

int is_severe(int16_t l0, int16_t l1, int16_t l2)
{
    int16_t runner_up = (l0 > l1) ? l0 : l1;
    return (l2 - runner_up) >= SEVERE_MARGIN_Q88;
}
```

DECISION: use the margin rule. Its 0.0093 cost is smaller than the 0.021
already accepted by dropping the L2 feature and the 0.016 accepted by
choosing h8 over h16 to fit the weight SRAM. Plain argmax remains the
fallback at 0.0198 if the subtraction ever proves awkward.

Note the margin is specific to the trained model. Retraining means
re-running `derive_margin.py`, exactly as it means regenerating the weight
image.

## 4. Loop settings table

Class to tracking-loop configuration, from the KPI sweep. Firmware table,
deliberately, so it is tunable without a re-spin.

| Class | PLL BW | FLL | T_coh | Band |
|---|---|---|---|---|
| NOMINAL | 5 Hz | off | 20 ms | L5 |
| DEGRADED | 15 Hz | off | 20 ms | L5 |
| SEVERE | 50 Hz | on | 10 ms | L5 |
| SPOOFED | hold | off | hold | hold |

The SEVERE row is what the KPI experiment measured: lock retention rises
from 66% at 5 Hz to 98.4% at 50 Hz under severe scintillation. The FLL and
coherent-integration entries are not yet backed by measurement and should be
marked as such.

---

## 5. What still needs deciding

**Saturated windows.** `sicu.saturated_o` flags a window where intensity
clipped. Options: substitute the previous S4, mark the prediction
low-confidence, or ignore. Saturation is most likely during rapid onset,
which is when the prediction matters most, so ignoring it is the worst
choice.

**Cold start.** The first 32 windows — 320 s — have no history. Stay in
BYPASS and report why.

**Confidence calibration.** The margin-to-4-bit mapping above is a guess.

**Threshold approximation.** Section 3's shortcut needs deriving and
validating, or the plain argmax accepted with its 0.019 F1 cost.
