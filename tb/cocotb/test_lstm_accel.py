"""
cocotb testbench for lstm_accel.

Checks the RTL against rtl/weights/golden_vectors.hex, produced by
python/ml/export_weights.py from the same checkpoint the weight image came
from. Both sides do identical Q8.8 arithmetic, so the logits must match
EXACTLY -- any difference is a real bug, not rounding.

The weight SRAM is modelled here rather than instantiated, so the test runs
without the PDK macro: 512 x 32, registered output (address sampled at one
edge, data valid after the next), contents from rtl/weights/weights.hex.

Written for cocotb 2.x: failures are plain assertions, not the removed
cocotb.result.TestFailure. Signals are read BEFORE the clock edge and driven
after it, so the ready/valid handshake samples the values the DUT actually
saw rather than post-edge ones.

Run:
    make -f Makefile.lstm sim
    make -f Makefile.lstm sim LSTM_TB_VECTORS=16
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WEIGHTS_HEX = os.path.join(ROOT, "rtl", "weights", "weights.hex")
GOLDEN_HEX = os.path.join(ROOT, "rtl", "weights", "golden_vectors.hex")

SEQ_LEN = 32


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def load_weights(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("//"):
                words.append(int(line, 16))
    assert len(words) == 512, "expected 512 words, got %d" % len(words)
    return words


def load_golden(path):
    vectors, seq, true_cls = [], [], None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("// vector"):
                seq, true_cls = [], int(line.split("true_class=")[1])
                continue
            if line.startswith("//"):
                continue
            if line.startswith("EXP"):
                p = line.split()
                vectors.append((seq, [s16(int(x, 16)) for x in p[1:4]],
                                int(p[4]), true_cls))
                seq = []
                continue
            a, b = line.split()
            seq.append((s16(int(a, 16)), s16(int(b, 16))))
    return vectors


async def weight_sram(dut, words):
    """512 x 32 read-only model with a registered output, active-low csb."""
    while True:
        # One iteration per clock: sample the request presented during this
        # cycle, then drive dout immediately after the edge, giving exactly
        # one cycle of read latency like the registered SKY130 macro.
        await ReadOnly()
        selected = dut.w_csb_o.value == 0
        addr = int(dut.w_addr_o.value) if selected else 0
        await RisingEdge(dut.clk_i)
        if selected:
            dut.w_dout_i.value = words[addr] if addr < len(words) else 0


async def reset(dut):
    dut.rst_ni.value = 0
    dut.start_i.value = 0
    dut.in_valid_i.value = 0
    dut.in_feat0_i.value = 0
    dut.in_feat1_i.value = 0
    dut.w_dout_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk_i)


async def run_vector(dut, seq, timeout=500000):
    """Drive one sequence with a correct ready/valid handshake."""
    dut.start_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.start_i.value = 0

    fed = 0
    # Present the first timestep and hold it until the DUT takes it.
    dut.in_feat0_i.value = seq[0][0] & 0xFFFF
    dut.in_feat1_i.value = seq[0][1] & 0xFFFF
    dut.in_valid_i.value = 1

    for cycle in range(timeout):
        await ReadOnly()
        accepted = (int(dut.in_valid_i.value) == 1
                    and int(dut.in_ready_o.value) == 1)
        done = int(dut.out_valid_o.value) == 1
        if done:
            result = ([s16(int(dut.logit0_o.value)),
                       s16(int(dut.logit1_o.value)),
                       s16(int(dut.logit2_o.value))],
                      int(dut.class_o.value), cycle)
            await RisingEdge(dut.clk_i)
            dut.in_valid_i.value = 0
            return result

        await RisingEdge(dut.clk_i)

        if accepted:
            fed += 1
            if fed < SEQ_LEN:
                dut.in_feat0_i.value = seq[fed][0] & 0xFFFF
                dut.in_feat1_i.value = seq[fed][1] & 0xFFFF
                dut.in_valid_i.value = 1
            else:
                dut.in_valid_i.value = 0

    dut.in_valid_i.value = 0
    raise AssertionError(
        "timeout after %d cycles, fed %d/%d timesteps" % (timeout, fed, SEQ_LEN))


@cocotb.test()
async def test_golden_vectors(dut):
    """Bit-exact comparison against the exported golden vectors."""
    words = load_weights(WEIGHTS_HEX)
    vectors = load_golden(GOLDEN_HEX)
    assert vectors, "no golden vectors parsed from %s" % GOLDEN_HEX

    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    cocotb.start_soon(weight_sram(dut, words))
    await reset(dut)

    n_check = min(int(os.environ.get("LSTM_TB_VECTORS", "4")), len(vectors))
    dut._log.info("checking %d of %d golden vectors" % (n_check, len(vectors)))

    fails = []
    for idx in range(n_check):
        seq, exp_logits, exp_class, true_cls = vectors[idx]
        assert len(seq) == SEQ_LEN, \
            "vector %d has %d timesteps, expected %d" % (idx, len(seq), SEQ_LEN)

        got_logits, got_class, cycles = await run_vector(dut, seq)

        ok = (got_logits == exp_logits) and (got_class == exp_class)
        if ok:
            dut._log.info("vector %d PASS  class=%d (true %d)  %d cycles"
                          % (idx, got_class, true_cls, cycles))
        else:
            fails.append(idx)
            dut._log.error(
                "vector %d FAIL  logits got %s expected %s  diff %s  "
                "class got %d expected %d"
                % (idx, got_logits, exp_logits,
                   [g - e for g, e in zip(got_logits, exp_logits)],
                   got_class, exp_class))

        await reset(dut)

    assert not fails, "%d of %d vectors mismatched: %s" % (
        len(fails), n_check, fails)
    dut._log.info("PASS: %d/%d vectors bit-exact" % (n_check, n_check))


@cocotb.test()
async def test_reset_and_idle(dut):
    """busy_o low out of reset, no spurious out_valid_o."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    cocotb.start_soon(weight_sram(dut, load_weights(WEIGHTS_HEX)))
    await reset(dut)

    for _ in range(20):
        await RisingEdge(dut.clk_i)
        await ReadOnly()
        assert int(dut.busy_o.value) == 0, "busy_o high while idle"
        assert int(dut.out_valid_o.value) == 0, "spurious out_valid_o"

    dut._log.info("PASS: idle behaviour clean")


@cocotb.test()
async def test_back_to_back(dut):
    """Two sequences without an intervening reset must agree."""
    words = load_weights(WEIGHTS_HEX)
    vectors = load_golden(GOLDEN_HEX)
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    cocotb.start_soon(weight_sram(dut, words))
    await reset(dut)

    seq, exp_logits, exp_class, _ = vectors[0]

    first, cls1, _ = await run_vector(dut, seq)
    await reset(dut)
    second, cls2, _ = await run_vector(dut, seq)

    assert first == second, (
        "back-to-back mismatch: %s then %s -- start_i does not clear state"
        % (first, second))
    assert cls1 == cls2
    assert second == exp_logits, \
        "second run wrong: got %s expected %s" % (second, exp_logits)

    dut._log.info("PASS: back-to-back runs consistent")
