"""
cocotb testbench for uart_rx.v

Strategy:
  - We don't have a real UART transmitter, so this testbench IS the
    transmitter: a helper coroutine (`uart_send_byte`) bit-bangs
    rx_line with the correct start/data/stop bit timing, matching
    whatever BAUD_RATE the DUT was compiled with.
  - After sending, we check the DUT's outputs: rx_valid pulses once,
    rx_data matches what we sent, framing_error stays low for a
    well-formed frame.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles

CLK_FREQ = 100_000_000   # must match the DUT's CLK_FREQ parameter
BAUD_RATE = 115200       # must match the DUT's BAUD_RATE parameter
BIT_PERIOD_NS = round(1e9 / BAUD_RATE)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, round(1e9 / CLK_FREQ), unit="ns").start())


async def reset_dut(dut):
    dut.rst.value = 1
    dut.rx_line.value = 1  # idle line is HIGH
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)


async def uart_send_byte(dut, byte_val, bad_stop_bit=False):
    """
    Bit-bang one UART frame onto dut.rx_line: start bit, 8 data bits
    (LSB first), stop bit. Set bad_stop_bit=True to deliberately send
    a framing error (stop bit driven LOW instead of HIGH).
    """
    # start bit
    dut.rx_line.value = 0
    await Timer(BIT_PERIOD_NS, unit="ns")

    # 8 data bits, LSB first
    for i in range(8):
        bit = (byte_val >> i) & 0x1
        dut.rx_line.value = bit
        await Timer(BIT_PERIOD_NS, unit="ns")

    # stop bit
    dut.rx_line.value = 0 if bad_stop_bit else 1
    await Timer(BIT_PERIOD_NS, unit="ns")

    # back to idle
    dut.rx_line.value = 1


async def wait_for_rx_valid(dut, timeout_bits=14):
    """Wait for rx_valid to pulse, with a timeout so a bug can't hang the test forever.
    A full frame is 10 bit periods (1 start + 8 data + 1 stop); 14 gives margin."""
    timeout_ns = BIT_PERIOD_NS * timeout_bits
    waited = 0
    step = round(1e9 / CLK_FREQ)
    while waited < timeout_ns:
        await RisingEdge(dut.clk)
        if dut.rx_valid.value == 1:
            return True
        waited += step
    return False


@cocotb.test()
async def test_single_byte(dut):
    """Send one known byte, check it comes out correctly."""
    await start_clock(dut)
    await reset_dut(dut)

    test_byte = 0xA5  # 10100101 - mix of 1s and 0s, good sanity pattern

    send_task = cocotb.start_soon(uart_send_byte(dut, test_byte))
    got_valid = await wait_for_rx_valid(dut)
    await send_task

    assert got_valid, "rx_valid never pulsed for a well-formed frame"
    assert dut.rx_data.value.to_unsigned() == test_byte, (
        f"rx_data = {dut.rx_data.value.to_unsigned():#04x}, expected {test_byte:#04x}"
    )
    assert dut.framing_error.value == 0, "framing_error asserted on a good frame"


@cocotb.test()
async def test_all_zero_and_all_one_bytes(dut):
    """Edge cases: 0x00 and 0xFF - no bit transitions within the byte."""
    await start_clock(dut)
    await reset_dut(dut)

    for test_byte in (0x00, 0xFF):
        send_task = cocotb.start_soon(uart_send_byte(dut, test_byte))
        got_valid = await wait_for_rx_valid(dut)
        await send_task

        assert got_valid, f"rx_valid never pulsed for byte {test_byte:#04x}"
        assert dut.rx_data.value.to_unsigned() == test_byte, (
            f"rx_data = {dut.rx_data.value.to_unsigned():#04x}, expected {test_byte:#04x}"
        )
        assert dut.framing_error.value == 0

        await ClockCycles(dut.clk, 20)  # small gap between frames


@cocotb.test()
async def test_random_bytes(dut):
    """Randomized regression: many random bytes back to back."""
    await start_clock(dut)
    await reset_dut(dut)

    random.seed(42)  # deterministic for repeatable CI runs
    test_bytes = [random.randint(0, 255) for _ in range(20)]

    for test_byte in test_bytes:
        send_task = cocotb.start_soon(uart_send_byte(dut, test_byte))
        got_valid = await wait_for_rx_valid(dut)
        await send_task

        assert got_valid, f"rx_valid never pulsed for byte {test_byte:#04x}"
        assert dut.rx_data.value.to_unsigned() == test_byte, (
            f"rx_data = {dut.rx_data.value.to_unsigned():#04x}, expected {test_byte:#04x}"
        )
        assert dut.framing_error.value == 0

        await ClockCycles(dut.clk, 10)


@cocotb.test()
async def test_framing_error(dut):
    """Deliberately send a bad stop bit -> framing_error should assert, rx_valid should NOT."""
    await start_clock(dut)
    await reset_dut(dut)

    send_task = cocotb.start_soon(uart_send_byte(dut, 0x3C, bad_stop_bit=True))

    # Poll both signals until one fires or we time out
    timeout_ns = BIT_PERIOD_NS * 14
    step = round(1e9 / CLK_FREQ)
    waited = 0
    saw_framing_error = False
    saw_valid = False
    while waited < timeout_ns:
        await RisingEdge(dut.clk)
        if dut.framing_error.value == 1:
            saw_framing_error = True
            break
        if dut.rx_valid.value == 1:
            saw_valid = True
            break
        waited += step

    await send_task

    assert saw_framing_error, "framing_error did not assert on a bad stop bit"
    assert not saw_valid, "rx_valid incorrectly asserted on a malformed frame"


@cocotb.test()
async def test_glitch_rejection(dut):
    """
    A very short LOW blip on rx_line (shorter than half a bit period)
    should NOT be mistaken for a start bit -- the FSM should return to
    IDLE and not produce a spurious rx_valid.
    """
    await start_clock(dut)
    await reset_dut(dut)

    # Blip: LOW for a small fraction of a bit period, then back HIGH
    dut.rx_line.value = 0
    await Timer(BIT_PERIOD_NS // 8, unit="ns")
    dut.rx_line.value = 1

    # Give it a couple of bit periods to settle - nothing should happen
    await Timer(BIT_PERIOD_NS * 2, unit="ns")

    assert dut.rx_valid.value == 0, "rx_valid fired on a noise glitch, not a real frame"
    assert dut.framing_error.value == 0, "framing_error fired on a noise glitch"

    # Confirm the DUT still works normally after the glitch
    test_byte = 0x7E
    send_task = cocotb.start_soon(uart_send_byte(dut, test_byte))
    got_valid = await wait_for_rx_valid(dut)
    await send_task

    assert got_valid, "DUT did not recover after glitch and failed to receive a real byte"
    assert dut.rx_data.value.to_unsigned() == test_byte
