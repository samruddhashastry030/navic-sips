"""cocotb testbench for uart_tx.

All stimulus is driven and all outputs sampled on the FALLING edge of clk_i.
The DUT updates on the rising edge, so staying half a cycle away avoids
read/write races that pass in one simulator and fail in another.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

DIVISOR = 10            # must match the wrapper
CLK_PERIOD_NS = 1_000


def expected_frame(byte):
    """8N1 frame, LSB first: start(0), 8 data bits, stop(1)."""
    return [0] + [(byte >> i) & 1 for i in range(8)] + [1]


async def reset_dut(dut):
    dut.rst_ni.value = 0
    dut.valid_i.value = 0
    dut.data_i.value = 0
    await ClockCycles(dut.clk_i, 5)
    await FallingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def send_byte(dut, byte):
    """Present one byte using the ready/valid handshake.

    Aligns to a falling edge FIRST. Without this, a caller that happens to be
    sitting on a rising edge would assert valid_i and clear it again half a
    cycle later, so the DUT never samples it and the byte is silently lost.
    """
    await FallingEdge(dut.clk_i)
    while dut.ready_o.value != 1:
        await FallingEdge(dut.clk_i)
    dut.data_i.value = byte
    dut.valid_i.value = 1
    await FallingEdge(dut.clk_i)
    dut.valid_i.value = 0


async def uart_monitor(dut, n_bits=10):
    """Sample tx_o once per bit period and return the bits seen."""
    while True:
        await FallingEdge(dut.clk_i)
        if dut.tx_o.value == 0:
            break

    bits = []
    for _ in range(n_bits):
        bits.append(int(dut.tx_o.value))
        await ClockCycles(dut.clk_i, DIVISOR)
        await FallingEdge(dut.clk_i)
    return bits


@cocotb.test()
async def test_idles_high(dut):
    """tx_o must idle high out of reset and ready_o must be asserted."""
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    await ClockCycles(dut.clk_i, 20)
    assert dut.tx_o.value == 1, "tx_o must idle high"
    assert dut.ready_o.value == 1, "ready_o must be high when idle"


@cocotb.test()
async def test_single_byte(dut):
    """Transmit 0xA5 and check the frame bit by bit."""
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    mon = cocotb.start_soon(uart_monitor(dut))
    await send_byte(dut, 0xA5)
    bits = await mon
    assert bits == expected_frame(0xA5), f"got {bits}"


@cocotb.test()
async def test_back_to_back(dut):
    """Send several bytes in sequence, respecting ready_o each time."""
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    for payload in (0x00, 0xFF, 0x55, 0x0F, 0x80, 0x3C):
        mon = cocotb.start_soon(uart_monitor(dut))
        await send_byte(dut, payload)
        bits = await mon
        assert bits == expected_frame(payload), f"0x{payload:02X}: got {bits}"
        await ClockCycles(dut.clk_i, DIVISOR * 2)


@cocotb.test()
async def test_ready_deasserts_while_busy(dut):
    """ready_o must drop for the whole frame and come back afterwards."""
    cocotb.start_soon(Clock(dut.clk_i, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)
    await send_byte(dut, 0x5A)
    await RisingEdge(dut.clk_i)
    assert dut.ready_o.value == 0, "ready_o must deassert while transmitting"
    await ClockCycles(dut.clk_i, DIVISOR * 11)
    assert dut.ready_o.value == 1, "ready_o must reassert after the frame"
