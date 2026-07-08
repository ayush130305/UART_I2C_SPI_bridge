"""
cocotb testbench for spi_master.v.

Mirrors tb_spi_master.v's mode-aware slave model, using cocotb's Edge
triggers (RisingEdge/FallingEdge work on ANY signal, not just a clock) -
this lets the slave coroutine watch sclk transitions directly, the same
way the Verilog version's `always @(posedge/negedge sclk)` did.
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

CLK_FREQ = 100_000_000


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, round(1e9 / CLK_FREQ), unit="ns").start())


async def reset_dut(dut):
    dut.rst.value = 1
    dut.start.value = 0
    dut.cpol.value = 0
    dut.cpha.value = 0
    dut.num_bytes.value = 0
    dut.tx_data.value = 0
    dut.wr_data.value = 0
    dut.byte_ack.value = 0
    dut.miso.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)


async def spi_slave(dut, canned_bytes, received_bytes):
    """Mirrors the Verilog mode-aware slave: drives miso, samples mosi,
    respecting whatever cpol/cpha the master is currently configured for."""
    byte_index = 0
    while True:
        await FallingEdge(dut.cs_n)
        cpol = dut.cpol.value
        cpha = dut.cpha.value
        tx_shift = canned_bytes[byte_index % len(canned_bytes)]
        rx_shift = 0
        bit_count = 0

        if cpha == 0:
            dut.miso.value = (tx_shift >> 7) & 1  # pre-tick setup

        while True:
            await dut.sclk.value_change
            if dut.cs_n.value == 1:
                break  # transaction ended while waiting
            new_sclk = dut.sclk.value
            if new_sclk != cpol:
                # leading edge
                if cpha == 0:
                    rx_shift = ((rx_shift << 1) | int(dut.mosi.value)) & 0xFF
                else:
                    dut.miso.value = (tx_shift >> 7) & 1
                    tx_shift = (tx_shift << 1) & 0xFF
            else:
                # trailing edge
                if cpha == 0:
                    if bit_count != 7:
                        tx_shift = (tx_shift << 1) & 0xFF
                        dut.miso.value = (tx_shift >> 7) & 1
                else:
                    rx_shift = ((rx_shift << 1) | int(dut.mosi.value)) & 0xFF

                if bit_count == 7:
                    received_bytes.append(rx_shift)
                    byte_index += 1
                    tx_shift = canned_bytes[byte_index % len(canned_bytes)]
                    bit_count = 0
                    if cpha == 0:
                        dut.miso.value = (tx_shift >> 7) & 1
                else:
                    bit_count += 1


async def spi_byte_ack_responder(dut):
    """Auto-ack immediately (no slow consumer to model here)."""
    while True:
        await RisingEdge(dut.clk)
        dut.byte_ack.value = 0
        if dut.byte_done.value == 1:
            dut.byte_ack.value = 1


async def spi_wr_data_server(dut, data_to_send):
    """Serves wr_data combinationally when byte_req pulses."""
    idx = [1]  # byte 0 goes out directly via tx_data
    while True:
        await RisingEdge(dut.clk)
        if idx[0] < len(data_to_send):
            dut.wr_data.value = data_to_send[idx[0]]
        if dut.byte_req.value == 1:
            idx[0] += 1


async def do_transfer(dut, n, mode, tx_data):
    dut.cpol.value = (mode >> 1) & 1
    dut.cpha.value = mode & 1
    dut.num_bytes.value = n
    dut.tx_data.value = tx_data[0]
    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0


async def wait_for_done(dut, timeout_cycles=5000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            return True
    return False


@cocotb.test()
async def test_all_four_modes(dut):
    """Single-byte transfer in each of the 4 SPI modes."""
    await start_clock(dut)
    await reset_dut(dut)

    for mode in range(4):
        received_bytes = []
        cocotb.start_soon(spi_slave(dut, [0xA5], received_bytes))
        cocotb.start_soon(spi_byte_ack_responder(dut))
        cocotb.start_soon(spi_wr_data_server(dut, [0x3C]))

        await do_transfer(dut, 1, mode, [0x3C])
        got_done = await wait_for_done(dut)

        assert got_done, f"mode {mode}: done never asserted"
        assert dut.rx_data.value.to_unsigned() == 0xA5, (
            f"mode {mode}: master captured {dut.rx_data.value.to_unsigned():#04x}, expected a5"
        )
        assert received_bytes == [0x3C], (
            f"mode {mode}: slave received {received_bytes}, expected [0x3c]"
        )
        await ClockCycles(dut.clk, 50)


@cocotb.test()
async def test_multibyte_continuous_cs(dut):
    """3-byte transfer, checking cs_n never glitches high mid-transaction."""
    await start_clock(dut)
    await reset_dut(dut)

    received_bytes = []
    cocotb.start_soon(spi_slave(dut, [0x99], received_bytes))
    cocotb.start_soon(spi_byte_ack_responder(dut))
    cocotb.start_soon(spi_wr_data_server(dut, [0x11, 0x22, 0x33]))

    cs_glitched = [False]

    async def watch_cs():
        while True:
            await RisingEdge(dut.clk)
            if dut.busy.value == 1 and dut.cs_n.value == 1:
                cs_glitched[0] = True

    cocotb.start_soon(watch_cs())

    await do_transfer(dut, 3, 0, [0x11, 0x22, 0x33])
    got_done = await wait_for_done(dut, timeout_cycles=10000)

    assert got_done, "multi-byte transfer never completed"
    assert not cs_glitched[0], "cs_n glitched high mid-transaction"
    assert received_bytes == [0x11, 0x22, 0x33], (
        f"slave received {received_bytes}, expected [0x11, 0x22, 0x33]"
    )
