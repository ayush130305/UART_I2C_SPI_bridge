/*
  arduino_i2c_test.ino

  Self-loopback I2C test, matching the same pattern as arduino_bridge_test.ino
  did for SPI: this ONE Arduino plays BOTH roles simultaneously -
    1) HOST: sends a UART command every 2 seconds telling the FPGA to
       run an I2C write-then-read transaction (register-read pattern).
    2) PERIPHERAL: responds as a real I2C slave (Wire library, AVR TWI
       hardware) at address 0x50 - the SAME address the command targets.
  So the round trip is: this Arduino -> UART -> FPGA -> I2C -> back to
  this same Arduino -> I2C response -> FPGA -> UART -> back to this Arduino.


  Wiring: NO VOLTAGE DIVIDER NEEDED for the I2C lines (open-drain, both
  sides only ever pull low or release):
    Arduino SDA (A4 on Uno) <-> FPGA JA9
    Arduino SCL (A5 on Uno) <-> FPGA JA10
    PLUS: external ~4.7k pull-up resistors from SDA to 3.3V and from
    SCL to 3.3V (NOT 5V - keeps the bus FPGA-safe, since Arduino only
    ever pulls low, never drives high, on a real I2C bus).
  UART wiring (unchanged from arduino_bridge_test.ino):
    Pin 0 (RX)  <- FPGA JA2 (UART TX)      direct wire
    Pin 1 (TX)  -> FPGA JA1 (UART RX)      THROUGH THE VOLTAGE DIVIDER
  Arduino GND <-> shared ground - required, same as always.

  Command sent: engine=I2C(01), R/W=1 (read-capable), length(read_count)=1,
  device_addr=0x50, write_count=1, register_addr=0x0F (arbitrary "register"
  to write before reading back). The FPGA should then read exactly 1 byte
  back from this same Arduino (via its onI2CRequest callback below),
  followed by 1 status byte (0x00 = success).
*/

#include <Wire.h>

const uint8_t I2C_SLAVE_ADDRESS = 0x50;

volatile uint8_t last_i2c_received = 0x00;
volatile uint8_t i2c_response_byte = 0x68;  
unsigned long last_send_time = 0;
const unsigned long SEND_INTERVAL_MS = 2000;

void setup() {
    Serial.begin(115200);
    pinMode(LED_BUILTIN, OUTPUT);

    Wire.begin(I2C_SLAVE_ADDRESS);
    Wire.onReceive(onI2CReceive);
    Wire.onRequest(onI2CRequest);
}

// Called (as interrupt-driven callback) when the FPGA writes to us over I2C
void onI2CReceive(int numBytes) {
    while (Wire.available() > 0) {
        last_i2c_received = Wire.read();
    }
}

// Called when the FPGA reads from us over I2C
void onI2CRequest() {
    Wire.write(i2c_response_byte);
    digitalWrite(LED_BUILTIN, HIGH);  // confirm an I2C read happened
    delay(50);
    digitalWrite(LED_BUILTIN, LOW);
}

void send_uart_byte(uint8_t b) {
    Serial.write(b);
}

void loop() {
    unsigned long now = millis();
    if (now - last_send_time >= SEND_INTERVAL_MS) {
        last_send_time = now;

        // Command byte: engine=I2C(01), R/W=1(read-capable), length-1=0000 (read_count=1)
        send_uart_byte(0b01100000);
        send_uart_byte(I2C_SLAVE_ADDRESS);  // device address
        send_uart_byte(1);                   // write_count = 1 (a register address follows)
        send_uart_byte(0x0C);                // arbitrary "register address" to write

        // Expect: 1 read byte back, then 1 status byte
        uint8_t read_byte = 0, status_byte = 0;
        bool got_read = false, got_status = false;
        unsigned long wait_start = millis();

        while ((!got_read || !got_status) && (millis() - wait_start) < 1000) {
            if (Serial.available() < 1) continue;
            uint8_t b = Serial.read();
            if (!got_read) {
                read_byte = b;
                got_read = true;
            } else {
                status_byte = b;
                got_status = true;
            }
        }
        (void)read_byte;
        (void)status_byte;
        // If either flag is false, the round timed out - just try again
        // next cycle rather than hanging forever.

        i2c_response_byte++;  // change what we'll respond with next time
    }
}
