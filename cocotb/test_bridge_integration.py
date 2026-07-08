"""
cocotb testbench for bridge_top.v (uart_rx -> dispatcher -> spi_master /
i2c_master -> uart_tx, all real modules, wired structurally).

The "host PC" and "SPI/I2C peripherals" are simulated here in Python,
since there's nothing else to play those roles.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer

CLK_FREQ  = 100_000_000
BAUD_RATE = 115200
BIT_PERIOD_NS = round(1e9 / BAUD_RATE)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, round(1e9 / CLK_FREQ), unit="ns").start())


async def reset_dut(dut):
    dut.rst.value = 1
    dut.host_tx_line.value = 1
    dut.miso.value = 0
    dut.i2c_sda_in.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)


async def host_send_byte(dut, data):
    dut.host_tx_line.value = 0  # start bit
    await Timer(BIT_PERIOD_NS, unit="ns")
    for i in range(8):
        dut.host_tx_line.value = (data >> i) & 1
        await Timer(BIT_PERIOD_NS, unit="ns")
    dut.host_tx_line.value = 1  # stop bit
    await Timer(BIT_PERIOD_NS, unit="ns")


async def host_receive_bytes(dut, received_list):
    """Bit-bangs UART reception in Python, standing in for a real host's
    own UART receiver - samples fpga_tx_line at bit-period midpoints."""
    while True:
        await FallingEdge(dut.fpga_tx_line)  # start bit begins
        await Timer(BIT_PERIOD_NS * 1.5, unit="ns")  # land in middle of D0
        value = 0
        for i in range(8):
            bit = int(dut.fpga_tx_line.value)
            value |= (bit << i)
            await Timer(BIT_PERIOD_NS, unit="ns")
        received_list.append(value)


# ---- SPI slave (mode 0 only needed for this integration test) ----
async def spi_slave(dut, canned_bytes, received_bytes):
    byte_index = 0
    while True:
        await FallingEdge(dut.cs_n)
        tx_shift = canned_bytes[byte_index % len(canned_bytes)]
        rx_shift = 0
        bit_count = 0
        dut.miso.value = (tx_shift >> 7) & 1

        while True:
            await dut.sclk.value_change
            if dut.cs_n.value == 1:
                break
            if dut.sclk.value == 1:
                rx_shift = ((rx_shift << 1) | int(dut.mosi.value)) & 0xFF
            else:
                if bit_count != 7:
                    tx_shift = (tx_shift << 1) & 0xFF
                    dut.miso.value = (tx_shift >> 7) & 1
                if bit_count == 7:
                    received_bytes.append(rx_shift)
                    byte_index += 1
                    tx_shift = canned_bytes[byte_index % len(canned_bytes)]
                    bit_count = 0
                    dut.miso.value = (tx_shift >> 7) & 1
                else:
                    bit_count += 1


# ---- I2C slave (bidirectional, same logic as test_i2c_master.py) ----
def recompute_sda(dut, shared):
    dut.i2c_sda_in.value = 0 if (dut.i2c_sda_oe.value == 1 or shared["slave_sda_oe"]) else 1


async def sda_bus_driver(dut, shared):
    while True:
        await dut.i2c_sda_oe.value_change
        recompute_sda(dut, shared)


def set_slave_sda_oe(dut, shared, value):
    shared["slave_sda_oe"] = value
    recompute_sda(dut, shared)


async def i2c_slave(dut, shared, write_bytes_seen, read_data_to_send):
    prev_scl = 0
    prev_sda = 1
    transaction_active = False
    mode = 0
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
        scl = int(dut.i2c_scl_oe.value) == 0
        sda = int(dut.i2c_sda_in.value)

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


@cocotb.test()
async def test_spi_single_byte(dut):
    """SPI single-byte transaction through the whole real bridge."""
    await start_clock(dut)
    await reset_dut(dut)

    received = []
    cocotb.start_soon(host_receive_bytes(dut, received))
    cocotb.start_soon(spi_slave(dut, [0xA5], []))

    await host_send_byte(dut, 0b00_0_0_0000)  # SPI, length=1
    await host_send_byte(dut, 0x3C)
    await Timer(200_000, unit="ns")

    assert received == [0xA5], f"host got {[hex(b) for b in received]}, expected [a5]"


@cocotb.test()
async def test_spi_multibyte(dut):
    """SPI 3-byte, continuous cs_n, through the whole real bridge."""
    await start_clock(dut)
    await reset_dut(dut)

    received = []
    cocotb.start_soon(host_receive_bytes(dut, received))
    cocotb.start_soon(spi_slave(dut, [0x99], []))

    await host_send_byte(dut, 0b00_0_0_0010)  # SPI, length=3
    await host_send_byte(dut, 0x11)
    await host_send_byte(dut, 0x22)
    await host_send_byte(dut, 0x33)
    await Timer(400_000, unit="ns")

    assert received == [0x99, 0x99, 0x99], f"host got {[hex(b) for b in received]}, expected 3x 99"


@cocotb.test()
async def test_i2c_write(dut):
    """I2C write-only through the whole real bridge."""
    await start_clock(dut)
    await reset_dut(dut)

    received = []
    cocotb.start_soon(host_receive_bytes(dut, received))
    shared = {"slave_sda_oe": False}
    cocotb.start_soon(sda_bus_driver(dut, shared))
    write_seen = []
    cocotb.start_soon(i2c_slave(dut, shared, write_seen, [0x00]))

    await host_send_byte(dut, 0b01_0_0_0010)  # I2C write, length=3
    await host_send_byte(dut, 0x50)           # device address
    await host_send_byte(dut, 0xAA)
    await host_send_byte(dut, 0xBB)
    await host_send_byte(dut, 0xCC)
    await Timer(700_000, unit="ns")

    assert write_seen == [0xA0, 0xAA, 0xBB, 0xCC], f"slave saw {[hex(b) for b in write_seen]}"
    assert received == [0x00], f"host got {[hex(b) for b in received]}, expected [00] (status)"


@cocotb.test()
async def test_i2c_combined_write_then_read(dut):
    """I2C combined write-then-read (WHO_AM_I pattern) through the whole real bridge."""
    await start_clock(dut)
    await reset_dut(dut)

    received = []
    cocotb.start_soon(host_receive_bytes(dut, received))
    shared = {"slave_sda_oe": False}
    cocotb.start_soon(sda_bus_driver(dut, shared))
    write_seen = []
    cocotb.start_soon(i2c_slave(dut, shared, write_seen, [0x68]))

    await host_send_byte(dut, 0b01_1_0_0000)  # I2C read-capable, length(read_count)=1
    await host_send_byte(dut, 0x68)           # device address
    await host_send_byte(dut, 1)              # write_count=1
    await host_send_byte(dut, 0x75)           # register address to write
    await Timer(900_000, unit="ns")

    assert received == [0x68, 0x00], f"host got {[hex(b) for b in received]}, expected [68, 00]"
    assert write_seen == [0xD0, 0x75, 0xD1], f"slave saw {[hex(b) for b in write_seen]}"
