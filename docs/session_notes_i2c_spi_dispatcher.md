# UART-to-SPI/I2C Bridge — Session Notes (I2C read, SPI modes, dispatcher integration)

## 1. Updated command byte format

| Bits | SPI meaning | I2C meaning |
|------|-------------|-------------|
| [7:6] | engine select: `00`=SPI, `01`=I2C | same |
| [5]   | CPOL | R/W (0=write, 1=read-capable) |
| [4]   | CPHA | reserved |
| [3:0] | length−1 = total bytes (cs_n held low for all of them) | length−1 = write count (R/W=0) or read count (R/W=1) |

**SPI sequence:** command byte → `length` data bytes → `length` result bytes streamed back (full-duplex, one result per input byte).

**I2C write (R/W=0):** command byte → device address byte → `length` write data bytes → 1 status byte (`0x00`=success, `0xFF`=ack_error).

**I2C read-capable (R/W=1):** command byte → device address byte → **write_count byte** (0–15; new, extra header byte only used in this mode) → `write_count` write data bytes (if >0) → transaction runs (write phase, then repeated-START, then read phase if both counts >0) → `length` (=read count) bytes streamed back as they arrive → 1 final status byte.

This one mechanism covers plain write, plain read, and the common "write register address, read back value" pattern (e.g. MPU6050 WHO_AM_I) depending on which counts are zero.

## 2. SPI master v2 — CPOL/CPHA + continuous multi-byte

- **Leading/trailing edge convention:** leading = first transition away from idle after CS asserts; trailing = transition back toward idle. Defining it this way makes sample/setup logic uniform regardless of CPOL.
  - CPHA=0: sample on leading, setup on trailing (plus one pre-tick setup at transfer start, since there's no earlier trailing edge to use for bit 0).
  - CPHA=1: setup on leading, sample on trailing.
- **Continuous `cs_n`:** one `start` pulse now covers a whole multi-byte transaction; `cs_n` stays low throughout, using a `byte_req`/`wr_data` handshake (same contract style as I2C's write path) to pull in bytes 2..N.
- **`byte_ack` backpressure (important, added after a real bug):** `spi_master` pauses after every byte (`BYTE_ACK_WAIT` state, `cs_n`/`sclk` held steady) until the consumer pulses `byte_ack`. Without this, a fast producer (SPI, ~8µs/byte) can outrun a slow consumer (UART TX, ~87µs/byte) and silently drop bytes, since `byte_done` is only a one-cycle pulse. **General pattern:** any producer that emits a pulse-style "data ready" signal to a much slower consumer needs an ack/handshake, not just a bare pulse.
- Dispatcher only sends `spi_byte_ack` *after* it has started sending the current byte over UART (not the instant it captures it) — that's what actually throttles SPI to the consumer's real pace.

## 3. I2C master v2 — read + repeated-START

- New inputs: `num_write_bytes`, `num_read_bytes` (either can be 0) — covers write-only, read-only, and combined write-then-read.
- **Repeated-START:** SDA released while SCL low → SCL released high → SDA pulled low while SCL still high (this is the repeated-START condition itself) → SCL pulled low again → send address+R byte. Only used when write phase finishes and a read phase follows.
- **Read bytes:** master releases SDA (`READ_SETUP`) so the slave can drive, samples on the hold tick (`READ_HOLD`). After 8 bits, master drives ACK (more bytes coming) or NACK (last byte) itself — this is the one place *master* generates ack/nack instead of checking it.
- Address byte is always 8 bits on the wire (7-bit address + R/W bit combined) — no separate handling needed from a normal data byte at the shift-register level.

## 4. Bug log — everything found this session, and why each matters generally

| # | Bug | Where | Lesson |
|---|-----|-------|--------|
| 1 | Off-by-one at write→read mode switch: slave loaded next byte but deferred driving it one edge too late | testbench slave model | When switching modes mid-protocol, drive the very first output on the *same* edge as the switch — don't defer by "one more edge," even if it seems natural. |
| 2 | Stale slave state (`mode`, counters) carried over between separate tests, causing real bus contention (`X`) | testbench slave model | Reset **all** bookkeeping explicitly before each test, not just the counters you remember — don't rely solely on protocol-level reset detection (like START) to clean up leftover state. |
| 3 | CPHA=1 never advanced `tx_shift` — `mosi` stuck on bit 7 forever | `spi_master.v` (real RTL bug) | When mirroring near-identical logic for two branches (CPHA=0 vs 1), check *both* got every step — one had shifting, the other didn't. |
| 4 | CPHA=1's `rx_data` capture read the stale pre-edge shift register, missing the final bit | `spi_master.v` (real RTL bug) | When a "last bit sample" and a "capture the finished byte" both happen on the *same* edge, the capture must use the freshly computed value directly, not the register (which won't reflect this edge's update yet). |
| 5 | Multi-byte `send_index` off-by-one — byte 0 duplicated, last byte never reached | testbench | If byte 0 is consumed directly (not through the request handshake), the request-serving index must start at 1, not 0. |
| 6 | **Byte_ack backpressure missing** — fast SPI producer silently dropped bytes a slow UART consumer couldn't keep up with | `spi_master.v` design gap (not a "bug" exactly — a missing handshake) | Any pulse-based "data ready" signal between mismatched-speed producer/consumer needs an explicit ack, or the faster side must be made to wait. |
| 7 | (Earlier session) Testbench race: blocking assignment to `tx_start` right at `@(posedge clk)` raced the DUT's own same-edge evaluation | multiple testbenches | Always use nonblocking assignment for signals driven into a DUT at the exact edge it samples them. |
| 8 | (Earlier session) Timeout-too-short, repeated several times across UART/SPI/I2C testbenches | testbenches | Calculate required cycles from real parameters (divisor × bits × margin) — don't guess a round number. |

## 5. Testing hierarchy — why three separate testbenches, not just the integration one

- **`tb_spi_master.v`** — only place that tests all 4 CPOL/CPHA modes and multi-byte/continuous-CS in isolation. The integration test only ever exercises mode 0.
- **`tb_i2c_master.v`** — only place that tests write/read/combined transactions without UART/dispatcher timing in the mix.
- **`tb_bridge_integration_full.v`** — the real end-to-end confidence check: real UART, real dispatcher, real SPI/I2C engines, no stubs except the necessarily-fake external peripherals.

When a bug shows up, standalone tests isolate *which* module it's in far faster than debugging through the whole stack at once — this played out repeatedly today (several "which side has the bug" bugs were only findable by tracing one module in isolation first).

Switch Vivado's simulation "top" between these three depending on what you're actually debugging; `tb_bridge_integration_full` is the one to return to before calling anything "done."
