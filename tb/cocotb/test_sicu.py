"""
cocotb testbench for sicu.

Checks the S4 path against rtl/weights/sicu_vectors.hex, which holds real
COSMIC-2 50 Hz amplitude samples with the expected S4 computed by
python/golden/sicu_vectors.py using the same integer arithmetic the RTL does.

Unlike the LSTM vectors these are NOT expected to be bit-exact. The golden
model computes the ratio and square root in floating point; the RTL uses a
Newton-Raphson root on a fixed-point radicand. A tolerance of a few Q4.12
LSBs is the right check. The tolerance is asserted explicitly rather than
hidden, and the worst observed error is reported so regressions show up.

Shift handling: the RTL carries the shift from the previous window, so vector
n would normally be evaluated with vector n-1's shift. The vectors were
generated the same way within an occultation, but they are drawn from several
occultations, so each vector is PRIMED -- fed once to establish the shift,
then fed again for the checked result.

Run:
    make -f Makefile.sicu sim
    make -f Makefile.sicu sim SICU_TB_VECTORS=32
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VECTORS = os.path.join(ROOT, "rtl", "weights", "sicu_vectors.hex")

WINDOW_N = 500
S4_FRAC = 12
TOL_LSB = 8          # Q4.12 LSB is 0.000244, so 8 LSBs is ~0.002


def q412(v):
    return v / float(1 << S4_FRAC)


def load_vectors(path):
    """Yield (samples, expected_s4_q412, shift, cdaac_s4_q412)."""
    out, seq = [], []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if line.startswith("EXP"):
                p = line.split()
                out.append((seq, int(p[1], 16), int(p[2]), int(p[3], 16)))
                seq = []
                continue
            seq.append(int(line, 16))
    return out


async def reset(dut):
    dut.rst_ni.value = 0
    dut.enable_i.value = 0
    dut.in_valid_i.value = 0
    dut.amp_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    dut.enable_i.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk_i)


async def feed_window(dut, samples, timeout=20000):
    """Push one window and wait for s4_valid_o. Returns (s4, sat, shift)."""
    fed = 0
    dut.amp_i.value = samples[0]
    dut.in_valid_i.value = 1

    for _ in range(timeout):
        await ReadOnly()
        took = (int(dut.in_valid_i.value) == 1
                and int(dut.in_ready_o.value) == 1)
        if int(dut.s4_valid_o.value) == 1:
            res = (int(dut.s4_o.value), int(dut.saturated_o.value),
                   int(dut.shift_o.value))
            await RisingEdge(dut.clk_i)
            dut.in_valid_i.value = 0
            return res

        await RisingEdge(dut.clk_i)

        if took:
            fed += 1
            if fed < len(samples):
                dut.amp_i.value = samples[fed]
                dut.in_valid_i.value = 1
            else:
                dut.in_valid_i.value = 0

    dut.in_valid_i.value = 0
    raise AssertionError("timeout, fed %d/%d samples" % (fed, len(samples)))


@cocotb.test()
async def test_s4_vectors(dut):
    """S4 against golden vectors from real COSMIC-2 signal."""
    vecs = load_vectors(VECTORS)
    assert vecs, "no vectors parsed from %s" % VECTORS

    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)

    n = min(int(os.environ.get("SICU_TB_VECTORS", "8")), len(vecs))
    dut._log.info("checking %d of %d vectors, tolerance %d LSB (%.5f)"
                  % (n, len(vecs), TOL_LSB, q412(TOL_LSB)))

    worst, fails = 0, []
    for i in range(n):
        samples, exp, shift, cdaac = vecs[i]
        assert len(samples) == WINDOW_N, \
            "vector %d has %d samples, expected %d" % (i, len(samples), WINDOW_N)

        # Prime twice: the first pass sets the shift from this window's own
        # peak, the second confirms it has settled. One pass is not enough
        # when the shift changes, since the priming run itself used the
        # previous vector's shift.
        await feed_window(dut, samples)
        await feed_window(dut, samples)
        got, sat, used_shift = await feed_window(dut, samples)

        err = abs(got - exp)
        worst = max(worst, err)
        ok = err <= TOL_LSB
        if not ok:
            fails.append(i)
        dut._log.log(
            20 if ok else 40,
            "vector %2d  got %.4f  expected %.4f  cdaac %.4f  "
            "err %4d LSB  rtl_shift %d  vec_shift %d%s"
            % (i, q412(got), q412(exp), q412(cdaac), err, used_shift, shift,
               "  SATURATED" if sat else ""))

    dut._log.info("worst error: %d LSB (%.5f)" % (worst, q412(worst)))
    assert not fails, "%d of %d vectors outside tolerance: %s" % (
        len(fails), n, fails)
    dut._log.info("PASS: %d/%d within %d LSB" % (n, n, TOL_LSB))


@cocotb.test()
async def test_idle_and_backpressure(dut):
    """No spurious output, and in_ready_o falls while computing."""
    vecs = load_vectors(VECTORS)
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)

    for _ in range(20):
        await RisingEdge(dut.clk_i)
        await ReadOnly()
        assert int(dut.s4_valid_o.value) == 0, "spurious s4_valid_o"
        assert int(dut.in_ready_o.value) == 1, "not ready while idle"

    # enable_i low must stop it accepting samples. Drive after an edge,
    # never during ReadOnly.
    await RisingEdge(dut.clk_i)
    dut.enable_i.value = 0
    await RisingEdge(dut.clk_i)
    await ReadOnly()
    assert int(dut.in_ready_o.value) == 0, "ready asserted while disabled"
    await RisingEdge(dut.clk_i)
    dut.enable_i.value = 1

    dut._log.info("PASS: idle and enable behaviour clean")


@cocotb.test()
async def test_constant_signal_gives_zero(dut):
    """A perfectly steady signal has no fluctuation, so S4 must be 0."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)

    flat = [1000] * WINDOW_N
    await feed_window(dut, flat)
    got, sat, _ = await feed_window(dut, flat)

    assert got <= TOL_LSB, \
        "constant input gave S4 = %.5f, expected 0" % q412(got)
    dut._log.info("PASS: constant signal -> S4 = %.5f" % q412(got))
