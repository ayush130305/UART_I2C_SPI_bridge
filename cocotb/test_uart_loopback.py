"""
cocotb testbench for uart_tx, exercised through uart_loopback.

Strategy: rather than writing a second bit-bang "checker" that samples
tx_line by hand (duplicating uart_rx's own logic and risking two wrongs
cancelling out), we wire tx_line straight into our already-verified
uart_rx and check that rx_data/rx_valid come out correctly. If TX's
timing/format is wrong, our known-good RX will catch it.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_FREQ = 100_000_000
BAUD_RATE = 115200


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, round(1e9 / CLK_FREQ), unit="ns").start())


async def reset_dut(dut):
    dut.rst.value = 1
    dut.tx_start.value = 0
    dut.tx_data.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)


async def send_and_wait(dut, byte_val, timeout_cycles=20000):
    """Pulse tx_start with tx_data set, then wait for the RX side to
    report rx_valid. Waits for tx_busy to clear first, since the RTL
    correctly ignores tx_start while busy - firing it too early just
    gets silently dropped. Returns True/False for whether it arrived
    in time."""
    while dut.tx_busy.value == 1:
        await RisingEdge(dut.clk)

    dut.tx_data.value = byte_val
    dut.tx_start.value = 1
    await RisingEdge(dut.clk)
    dut.tx_start.value = 0

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.rx_valid.value == 1:
            return True
    return False


@cocotb.test()
async def test_single_byte_loopback(dut):
    """Send one byte through TX, confirm RX receives it correctly."""
    await start_clock(dut)
    await reset_dut(dut)

    test_byte = 0x5A
    got_valid = await send_and_wait(dut, test_byte)

    assert got_valid, "rx_valid never asserted - TX/RX loopback failed"
    assert dut.rx_data.value.to_unsigned() == test_byte, (
        f"rx_data = {dut.rx_data.value.to_unsigned():#04x}, expected {test_byte:#04x}"
    )
    assert dut.framing_error.value == 0, "framing_error asserted on a clean loopback"


@cocotb.test()
async def test_edge_case_bytes_loopback(dut):
    """0x00 and 0xFF - no bit transitions within the byte."""
    await start_clock(dut)
    await reset_dut(dut)

    for test_byte in (0x00, 0xFF):
        got_valid = await send_and_wait(dut, test_byte)
        assert got_valid, f"rx_valid never asserted for byte {test_byte:#04x}"
        assert dut.rx_data.value.to_unsigned() == test_byte
        assert dut.framing_error.value == 0
        await ClockCycles(dut.clk, 50)  # gap before next send


@cocotb.test()
async def test_random_bytes_loopback(dut):
    """Randomized regression across the full TX->RX round trip."""
    await start_clock(dut)
    await reset_dut(dut)

    random.seed(7)
    test_bytes = [random.randint(0, 255) for _ in range(20)]

    for test_byte in test_bytes:
        got_valid = await send_and_wait(dut, test_byte)
        assert got_valid, f"rx_valid never asserted for byte {test_byte:#04x}"
        assert dut.rx_data.value.to_unsigned() == test_byte, (
            f"rx_data = {dut.rx_data.value.to_unsigned():#04x}, expected {test_byte:#04x}"
        )
        assert dut.framing_error.value == 0
        await ClockCycles(dut.clk, 50)


@cocotb.test()
async def test_tx_busy_flag(dut):
    """tx_busy should assert immediately on tx_start and clear only after
    the full frame (10 bit periods) has actually gone out."""
    await start_clock(dut)
    await reset_dut(dut)

    dut.tx_data.value = 0xC3
    dut.tx_start.value = 1
    await RisingEdge(dut.clk)
    dut.tx_start.value = 0

    await RisingEdge(dut.clk)
    assert dut.tx_busy.value == 1, "tx_busy did not assert after tx_start"

    # busy should stay high for a while - check shortly after start
    await ClockCycles(dut.clk, 100)
    assert dut.tx_busy.value == 1, "tx_busy dropped too early, before the frame finished"

    # wait for it to actually clear (with generous timeout)
    for _ in range(20000):
        await RisingEdge(dut.clk)
        if dut.tx_busy.value == 0:
            break
    assert dut.tx_busy.value == 0, "tx_busy never cleared after transmission should have finished"


@cocotb.test()
async def test_back_to_back_bytes(dut):
    """Send two bytes back to back (waiting for busy to clear between them,
    as a real dispatcher would) and confirm both arrive correctly and in order."""
    await start_clock(dut)
    await reset_dut(dut)

    bytes_to_send = [0x11, 0x92]
    received = []

    for b in bytes_to_send:
        # wait until not busy before sending (real dispatcher behavior)
        while dut.tx_busy.value == 1:
            await RisingEdge(dut.clk)
        got_valid = await send_and_wait(dut, b)
        assert got_valid, f"rx_valid never asserted for byte {b:#04x}"
        received.append(dut.rx_data.value.to_unsigned())

    assert received == bytes_to_send, f"received {received}, expected {bytes_to_send}"
