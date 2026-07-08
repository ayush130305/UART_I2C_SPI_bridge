# UART RX Module — Reference Notes

## 1. Protocol basics

- No shared clock between TX and RX — both sides agree on a baud rate in advance.
- Frame: 1 start bit (LOW) → 8 data bits (LSB first) → 1 stop bit (HIGH).
- Idle line state = HIGH.
- UART's asynchronous nature means the receiver must derive all timing from
  a single event: the falling edge of the start bit.

## 2. FSM — four states

```
IDLE → START_BIT → DATA → STOP_BIT → (back to IDLE)
```

| State      | Trigger to enter                          | What happens                                                      | Trigger to leave                                         |
|------------|--------------------------------------------|---------------------------------------------------------------------|------------------------------------------------------------|
| IDLE       | reset, or previous frame completed         | wait for line to drop                                               | `rx_line == 0` → START_BIT                                 |
| START_BIT  | falling edge detected                      | count to bit-period midpoint, re-check the line (glitch rejection)  | still LOW at midpoint → DATA; HIGH → IDLE (was noise)       |
| DATA       | confirmed real start bit                   | sample each of 8 bits at successive midpoints, shift into register  | 8th bit sampled → STOP_BIT                                  |
| STOP_BIT   | 8 bits captured                            | check line HIGH at midpoint                                         | HIGH → latch `rx_data`, pulse `rx_valid`; LOW → `framing_error` — either way, back to IDLE |

See diagram below.

## 3. Two nested counters

1. **Tick generator** (system clock → oversample ticks): a free-running
   counter dividing the system clock down to `OVERSAMPLE` (e.g. 16) ticks
   per bit period. Runs continuously, independent of FSM state.
2. **Sample counter** (inside the FSM): counts *ticks*, not raw system
   clock cycles, to find bit-period midpoints. Gated by the tick pulse —
   without that gate, timing would be off by a factor of `DIVISOR`.

### Key counter values (all follow the "counting from 0" rule)

| Purpose                              | Target value      | Why                                                             |
|---------------------------------------|--------------------|------------------------------------------------------------------|
| Tick pulse (divider)                  | `DIVISOR - 1`      | Counting 0..DIVISOR-1 inclusive = DIVISOR total cycles            |
| Start bit midpoint check              | `OVERSAMPLE/2 - 1` | Half of one bit period, 0-indexed                                |
| Every subsequent bit midpoint (D0..D7, stop bit) | `OVERSAMPLE - 1` | One *full* bit period forward from the previous midpoint |

**Divisor formula:**
```
DIVISOR = CLK_FREQ / (BAUD_RATE * OVERSAMPLE)
```
e.g. 100,000,000 / (115200 × 16) ≈ 54.25 → truncates to 54 with a plain
integer divider.

## 4. Glitch rejection (why START_BIT re-checks the line)

A falling edge alone doesn't confirm a real start bit — could be noise.
At the midpoint of what might be the start bit, re-check the line level:
- still LOW → confirmed, proceed to DATA
- back HIGH → was a glitch, abort to IDLE, don't read any data

This is a **level check at one instant**, not a second edge-detection.

## 5. Shift register direction

```verilog
shift_reg <= {rx_line, shift_reg[7:1]};
```
New bit enters at bit 7 (MSB side), everything shifts right, bit 0 discarded.
Since UART sends **LSB first**, the first-arriving bit (D0) ends up at the
LSB of the final byte after 8 shifts, and the last-arriving bit (D7) ends up
at the MSB — this is correct, not a bug.

## 6. bit_index overflow protection

`bit_index` is 3 bits wide (0–7). Incrementing unconditionally at bit_index
== 7 would silently wrap to 0 (fixed-width overflow), causing the FSM to
loop forever inside DATA instead of moving to STOP_BIT. The `if
(bit_index == 7) → STOP_BIT` branch exists specifically to catch this
before overflow happens.

**General pattern to remember:** whenever a fixed-width counter reaches
its max value, check for that explicitly — don't rely on "just keep
incrementing."

## 7. framing_error — what it actually means

`framing_error` is a **symptom flag, not a diagnosis**. It just means "the
line wasn't HIGH where the stop bit was expected." Two very different root
causes produce the identical flag:

1. **Baud rate drift** — receiver's accumulated timing error has crept far
   enough that it's no longer sampling the real stop bit at all.
2. **No gap between bytes** — the next byte's start bit (LOW) arrives
   before the current frame's stop-bit check completes.

Distinguishing these requires separate investigation (waveform inspection,
checking for drift, checking test/host timing) — the single-bit flag alone
can't tell you which happened.

## 8. Baud rate drift (fractional divisor problem)

Plain integer divider truncates 54.25 → 54. This error is **not**
averaged out by oversampling — oversampling only helps avoid sampling near
bit *edges*, it does nothing for a systematically wrong tick rate.

- Error per tick ≈ 0.25 system-clock cycles
- By D7 (136 ticks elapsed: 16 for start bit + 7×16 for D0–D6 + 8 to reach
  D7's midpoint): accumulated error ≈ 34 cycles
- One bit period ≈ 868 cycles → drift ≈ 3.9% by D7
- UART typically tolerates ~2% — **this exceeds tolerance**

**Fix (deferred for this project's timeline):** fractional accumulator /
NCO (numerically controlled oscillator) — add the exact fractional divisor
each cycle using extra fixed-point bits, emit a tick on overflow, keep the
remainder rather than resetting to zero. Averages out to the exact rate
over time instead of a one-directional systematic error.

## 9. Testbench methodology — verified two ways

### cocotb + Icarus Verilog
- `uart_send_byte()` coroutine bit-bangs `rx_line` with correct timing
  (the testbench acts as the transmitter, since there isn't a real one).
- Tests: single byte, 0x00/0xFF edge cases, 20 random bytes (seeded),
  framing error (bad stop bit), glitch rejection.
- **Bug found:** first draft used `timeout_bits=3` while a full frame
  takes 10 bit periods — all tests failed on a testbench timing bug, not
  an RTL bug. Fixed by raising the timeout margin.

### Plain Verilog + Vivado XSim
- Same approach, using a `task` instead of a Python coroutine.
- **Bug found:** `rx_valid` pulses for exactly one clock cycle. The first
  draft called `check_byte` *after* `send_byte` returned — but the pulse
  had already happened and vanished during `send_byte`'s final delay.
  Sequential code can't "listen" to something mid-delay in another task.
- **Fix:** background `always @(posedge clk)` block that latches
  `rx_valid`/`rx_data`/`framing_error` the instant they appear, independent
  of what the sequential test code is doing. Reusable pattern — will need
  this again for SPI/I2C testbenches, since any short pulse output has the
  same risk.

### Result
All tests pass in both simulators, with matching timestamps down to the
nanosecond — strong cross-verification before ever touching real hardware.

## 10. General patterns worth carrying into SPI/I2C

- "Counting from 0" → always subtract 1 from a target count.
- Fixed-width counters need explicit overflow checks at their max value.
- Any short-pulse output signal needs a background latch in a purely
  sequential testbench, or concurrent polling in cocotb.
- A testbench failure doesn't mean the RTL is wrong — check test timing
  assumptions first.
