# UART-to-SPI/I2C Debug Bridge

An FPGA module that lets a host PC control SPI and I2C peripherals over a
simple UART command interface — similar in spirit to a Bus Pirate / FT4222.

Verified in simulation (Icarus Verilog + cocotb, and Vivado XSim) and on
real hardware (Digilent Basys 3 + Arduino Uno).

## Architecture

```
Host (UART) ──► uart_rx ──► dispatcher ──► spi_master ──► SPI peripheral
                                       └──► i2c_master ──► I2C peripheral
Host (UART) ◄── uart_tx ◄── dispatcher ◄───────────────────────┘
```

`dispatcher.v` reads a command byte from `uart_rx`, decodes which engine
(SPI or I2C) and how many bytes are involved, drives the corresponding
engine, and streams results back through `uart_tx`.

## Command byte format

`[7:6]` = engine select (`00`=SPI, `01`=I2C)

**SPI (engine=00):**
`[5]`=CPOL, `[4]`=CPHA, `[3:0]`=length−1 (total bytes, `cs_n` held low
continuously for all of them). Sequence: command → N data bytes → N
result bytes (SPI is full-duplex, one result per input byte).

**I2C (engine=01):**
`[5]`=R/W, `[4]`=reserved, `[3:0]`=length−1.
- R/W=0 (write): length = write-byte count. Sequence: command →
  device_addr → N write bytes → 1 status byte (`0x00`=success,
  `0xFF`=ack_error).
- R/W=1 (read-capable): length = read-byte count. Sequence: command →
  device_addr → write_count byte (0–15) → write_count data bytes (if
  >0) → N read bytes streamed back → 1 status byte. Covers write-only,
  read-only, and combined write-then-read (register-read pattern, via
  repeated-START) depending on which counts are zero.

## Repo structure

```
rtl/          Synthesizable Verilog - the actual design
constraints/  Vivado XDC for the Basys 3
tb/           Plain Verilog testbenches (Vivado/XSim compatible)
cocotb/       Python/cocotb testbenches (Icarus Verilog)
arduino/      Arduino sketches used as test peripherals/host
docs/         Session notes, design decisions, bug log
```

### rtl/

| File | Purpose |
|---|---|
| `uart_rx.v` / `uart_tx.v` | UART receiver/transmitter, 16x oversampled |
| `spi_master.v` | SPI master, all 4 CPOL/CPHA modes, continuous multi-byte `cs_n`, `byte_ack` backpressure |
| `i2c_master.v` | I2C master, write/read/combined (repeated-START) |
| `dispatcher.v` | Routes UART commands to SPI/I2C, streams results back |
| `bridge_top.v` | Structural wrapper: wires the above together, simulation-friendly toplevel |
| `basys3_top.v` | Real hardware toplevel: wraps `bridge_top`, adds 7-segment display, switch-triggered demo message, board-specific pin mapping |
| `seven_seg_driver.v` | Drives Basys 3's 4-digit multiplexed display |
| `debounce.v` / `switch_string_sender.v` | Switch-triggered "AYUSH" UART message demo |
| `uart_loopback.v` | TX→RX loopback wrapper (early-stage sanity module) |

## Building for hardware (Vivado)

1. Add everything in `rtl/` as design sources, `constraints/basys3_top.xdc`
   as the constraints file, with `basys3_top` set as the top module.
2. Synthesis → Implementation → Generate Bitstream → Program Device.

## Simulating (two independent workflows, both verified)

**Plain Verilog + Vivado XSim:** add the relevant `tb/tb_*.v` file to
`sim_1`, set it as top, Run Behavioral Simulation, `run all` in the Tcl
console.

**cocotb + Icarus Verilog** (see `docs/` for the debugging notes on why
some quirks exist):
```
cd cocotb/
py -3.13 test_runner_spi.py       # or test_runner_i2c.py / test_runner_bridge.py / test_runner.py
```
Requires Python <=3.13, `pip install "cocotb~=2.0"`, and Icarus Verilog
on PATH. Waveforms auto-generate via `waves=True` in each runner
(`.fst` files under `sim_build/`, viewable in GTKWave).

## Hardware setup (Basys 3 + Arduino Uno)

**UART** (needs a voltage divider - Arduino is 5V logic, FPGA is 3.3V):

| Arduino | FPGA (Pmod JA) |
|---|---|
| TX (pin 1) | JA1 - via divider |
| RX (pin 0) | JA2 - direct |

**SPI:**

| Arduino | FPGA (Pmod JA) |
|---|---|
| SCK (13) | JA3 - direct |
| MOSI (11) | JA4 - direct |
| MISO (12) | JA7 - via divider |
| SS (10) | JA8 - direct |

**I2C** (open-drain - no divider needed, just shared 3.3V pull-ups):

| Arduino | FPGA (Pmod JA) |
|---|---|
| SDA (A4) | JA9 - direct, + ~4.7-10k ohm pull-up to 3.3V |
| SCL (A5) | JA10 - direct, + ~4.7-10k ohm pull-up to 3.3V |

Plus a shared ground wire between both boards (required, easy to forget).

**Divider circuit** (for the two signals Arduino drives into the FPGA):
```
5V source --[R1]--*--[R2]-- GND
                   |
             FPGA pin (~3.3V)
```
Tested with R1=1k/R2=2k and with R1=10k/R2=10k+10k (ratio is what
matters, not absolute value).

### Arduino sketches

| Sketch | Role |
|---|---|
| `arduino_bridge_test.ino` | Host (sends SPI command) + SPI slave, self-loopback test |
| `arduino_i2c_test.ino` | Host (sends I2C command) + I2C slave, self-loopback test |
| `arduino_combined_test.ino` | All of the above combined, alternates SPI/I2C each round |
| `arduino_bridge_interactive.ino` | Type-a-byte-in-Serial-Monitor version (uses SoftwareSerial - has known reliability trade-offs, see docs) |

## Waveforms

Screenshots from actual waveform verification (Vivado XSim and GTKWave),
confirming behavior visually rather than just trusting PASS/FAIL text.

### SPI

**Single-byte transfer** - `cs_n` drops for one byte, `sclk`/`mosi`/`miso`
active throughout:

![SPI single byte](docs/waveforms/spi_single_byte_full.png)
![SPI single byte zoom](docs/waveforms/spi_single_byte_zoom.png)

**All 4 CPOL/CPHA modes tested**, and the gap between separate transfers
- `sclk` correctly goes silent when `cs_n` is idle, confirming clean
transaction boundaries:

![SPI modes](docs/waveforms/spi_modes_wide.png)
![SPI cs_n gap zoom](docs/waveforms/spi_cs_gap_zoom.png)

### I2C

**Write transaction**, and the **combined write-then-read** (register-read
pattern) showing the repeated-START sequence:

![I2C write](docs/waveforms/i2c_write_wide.png)
![I2C combined write-then-read](docs/waveforms/i2c_combined_wide.png)

**Zoomed on the repeated-START region** - `state` transitions through
`RSTART_PREP` -> `RSTART_SCLHIGH` -> `RSTART_SDALOW` -> `RSTART_SCLLOW`
before re-sending the address with R/W=1:

![I2C repeated-START zoom](docs/waveforms/i2c_repeated_start_zoom.png)

### Full bridge integration

**All 4 integration tests in one continuous run** (SPI single-byte, SPI
multi-byte, I2C write, I2C combined) - `disp_inst.state` visibly steps
through a different path (`05->06->07->09` vs `05->07->09`) depending on
whether the command uses R/W=0 or R/W=1, confirmed at the waveform
level, not just inferred from the PASS message:

![Full bridge integration](docs/waveforms/bridge_integration_full.png)
![Bridge integration zoom](docs/waveforms/bridge_integration_zoom1.png)
![Dispatcher branch confirmation](docs/waveforms/bridge_dispatcher_branch_zoom.png)

## Status

- DONE: UART (RX/TX/loopback) - verified in simulation and hardware
- DONE: SPI (all 4 modes, multi-byte continuous cs_n) - verified in simulation and hardware
- DONE: I2C (write/read/combined via repeated-START) - verified in simulation and hardware
- DONE: Dispatcher routing both engines - verified in simulation and hardware
- TODO: Error handling for malformed commands
- TODO: I2C clock stretching
- TODO: Constrained-random/coverage testing

See `docs/` for the full bug log and design-decision notes from
development.
