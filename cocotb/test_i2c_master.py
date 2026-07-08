"""
cocotb testbench for i2c_master.v.

Manual open-drain bus resolution: unlike the Verilog testbench (which used
`assign sda_line = ... ? 0 : 1'bz;` twice, letting the simulator resolve
multiple drivers automatically), cocotb has no equivalent for a signal
driven from Python. Here sda_in is resolved explicitly: LOW if EITHER the
master (dut.sda_oe) or the slave (shared['slave_sda_oe']) is pulling it
low, HIGH otherwise (the "pull-up").
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_FREQ = 100_000_000
SCL_FREQ = 100_000


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, round(1e9 / CLK_FREQ), unit="ns").start())


async def reset_dut(dut, shared):
    dut.rst.value = 1
    dut.start.value = 0
    dut.dev_addr.value = 0
    dut.num_write_bytes.value = 0
    dut.num_read_bytes.value = 0
    dut.wr_data.value = 0
    shared["slave_sda_oe"] = False
    recompute_sda(dut, shared)
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)


def recompute_sda(dut, shared):
    dut.sda_in.value = 0 if (dut.sda_oe.value == 1 or shared["slave_sda_oe"]) else 1


async def sda_bus_driver(dut, shared):
    while True:
        await dut.sda_oe.value_change
        recompute_sda(dut, shared)


def set_slave_sda_oe(dut, shared, value):
    shared["slave_sda_oe"] = value
    recompute_sda(dut, shared)


async def i2c_slave(dut, shared, write_bytes_seen, read_data_to_send):
    """Bidirectional fake I2C slave: receives address+data, ACKs
    everything, switches to SEND mode after ACKing an address byte whose
    R/W bit is 1, then drives canned bytes back (ignoring the master's
    own ack/nack, since we always send exactly len(read_data_to_send))."""
    prev_scl = 0
    prev_sda = 1
    transaction_active = False
    mode = 0  # 0=RECEIVE, 1=SEND
    slave_shift = 0
    bits_seen = 0
    driving_ack = False
    is_first_byte = True
    pending_send_switch = False
    send_shift = 0
    send_bits_done = 0
    send_idx = [0]

    while True:
        await RisingEdge(dut.clk)
        scl = int(dut.scl_oe.value) == 0  # released -> high (no clock stretching)
        sda = int(dut.sda_in.value)

        if prev_scl == 1 and scl == 1 and prev_sda == 1 and sda == 0:
            transaction_active = True
            bits_seen = 0
            mode = 0
            driving_ack = False
            is_first_byte = True
            pending_send_switch = False
        elif prev_scl == 1 and scl == 1 and prev_sda == 0 and sda == 1:
            transaction_active = False
            set_slave_sda_oe(dut, shared, False)
        elif transaction_active and prev_scl == 0 and scl == 1:
            if mode == 0 and bits_seen < 8:
                slave_shift = ((slave_shift << 1) | sda) & 0xFF
                bits_seen += 1
        elif transaction_active and prev_scl == 1 and scl == 0:
            if mode == 0:
                if bits_seen == 8 and not driving_ack:
                    set_slave_sda_oe(dut, shared, True)
                    driving_ack = True
                    write_bytes_seen.append(slave_shift)
                    if is_first_byte and (slave_shift & 1) == 1:
                        pending_send_switch = True
                    is_first_byte = False
                elif driving_ack:
                    set_slave_sda_oe(dut, shared, False)
                    driving_ack = False
                    bits_seen = 0
                    if pending_send_switch:
                        mode = 1
                        pending_send_switch = False
                        first_byte = read_data_to_send[send_idx[0] % len(read_data_to_send)]
                        set_slave_sda_oe(dut, shared, ((first_byte >> 7) & 1) == 0)
                        send_shift = (first_byte << 1) & 0xFF
                        send_bits_done = 1
                        send_idx[0] += 1
            else:
                if send_bits_done < 8:
                    bit_val = (send_shift >> 7) & 1
                    set_slave_sda_oe(dut, shared, bit_val == 0)
                    send_shift = (send_shift << 1) & 0xFF
                    send_bits_done += 1
                else:
                    set_slave_sda_oe(dut, shared, False)
                    send_bits_done = 0
                    send_shift = read_data_to_send[send_idx[0] % len(read_data_to_send)]
                    send_idx[0] += 1

        prev_scl = scl
        prev_sda = sda


async def do_i2c_transaction(dut, addr, nwrite, nread, wr_data_list):
    idx = [0]

    async def wr_data_server():
        while True:
            await RisingEdge(dut.clk)
            if idx[0] < len(wr_data_list):
                dut.wr_data.value = wr_data_list[idx[0]]
            if dut.byte_req.value == 1:
                idx[0] += 1

    cocotb.start_soon(wr_data_server())

    dut.dev_addr.value = addr
    dut.num_write_bytes.value = nwrite
    dut.num_read_bytes.value = nread
    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0


async def wait_for_done(dut, timeout_cycles=60000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            return True
    return False


@cocotb.test()
async def test_write_only(dut):
    """Write-only regression: address + 3 data bytes."""
    await start_clock(dut)
    shared = {"slave_sda_oe": False}
    await reset_dut(dut, shared)
    cocotb.start_soon(sda_bus_driver(dut, shared))

    write_bytes_seen = []
    cocotb.start_soon(i2c_slave(dut, shared, write_bytes_seen, [0x00]))

    await do_i2c_transaction(dut, 0x50, 3, 0, [0xAA, 0xBB, 0xCC])
    got_done = await wait_for_done(dut)

    assert got_done, "transaction never completed"
    assert dut.ack_error.value == 0, "ack_error asserted unexpectedly"
    assert write_bytes_seen == [0xA0, 0xAA, 0xBB, 0xCC], (
        f"slave saw {[hex(b) for b in write_bytes_seen]}, expected [a0, aa, bb, cc]"
    )


@cocotb.test()
async def test_read_only(dut):
    """Read-only: address+R, read 3 bytes back."""
    await start_clock(dut)
    shared = {"slave_sda_oe": False}
    await reset_dut(dut, shared)
    cocotb.start_soon(sda_bus_driver(dut, shared))

    write_bytes_seen = []
    cocotb.start_soon(i2c_slave(dut, shared, write_bytes_seen, [0x11, 0x22, 0x33]))

    captured = []

    async def read_capture():
        while True:
            await RisingEdge(dut.clk)
            if dut.read_byte_valid.value == 1:
                captured.append(dut.read_byte_data.value.to_unsigned())

    cocotb.start_soon(read_capture())

    await do_i2c_transaction(dut, 0x68, 0, 3, [])
    got_done = await wait_for_done(dut)

    assert got_done, "transaction never completed"
    assert dut.ack_error.value == 0
    assert captured == [0x11, 0x22, 0x33], f"captured {[hex(b) for b in captured]}, expected [11,22,33]"
    assert write_bytes_seen == [0xD1], f"slave saw address byte {[hex(b) for b in write_bytes_seen]}, expected [d1]"


@cocotb.test()
async def test_combined_write_then_read(dut):
    """Combined write-then-read via repeated-START (WHO_AM_I pattern)."""
    await start_clock(dut)
    shared = {"slave_sda_oe": False}
    await reset_dut(dut, shared)
    cocotb.start_soon(sda_bus_driver(dut, shared))

    write_bytes_seen = []
    cocotb.start_soon(i2c_slave(dut, shared, write_bytes_seen, [0x68]))

    captured = []

    async def read_capture():
        while True:
            await RisingEdge(dut.clk)
            if dut.read_byte_valid.value == 1:
                captured.append(dut.read_byte_data.value.to_unsigned())

    cocotb.start_soon(read_capture())

    await do_i2c_transaction(dut, 0x68, 1, 1, [0x75])
    got_done = await wait_for_done(dut)

    assert got_done, "transaction never completed"
    assert dut.ack_error.value == 0
    assert captured == [0x68], f"captured {[hex(b) for b in captured]}, expected [68]"
    assert write_bytes_seen == [0xD0, 0x75, 0xD1], (
        f"slave saw {[hex(b) for b in write_bytes_seen]}, expected [d0, 75, d1]"
    )
