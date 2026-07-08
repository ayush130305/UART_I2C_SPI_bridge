/*
  arduino_combined_test.ino

  Combines everything into one sketch:
    1) UART HOST: every 2 seconds, sends EITHER an SPI command OR an I2C
       command to the FPGA, alternating each round, so both paths get
       exercised over time.
    2) SPI SLAVE: responds to the FPGA's spi_master via the AVR hardware
       SPI peripheral (interrupt-driven), same as arduino_bridge_test.ino.
    3) I2C SLAVE: responds to the FPGA's i2c_master via the AVR hardware
       TWI peripheral (Wire library, slave mode), same as
       arduino_i2c_test.ino.
    4) AYUSH marker handling: recognizes the 0x02 marker byte from the
       switch-triggered "AYUSH" message and consumes it separately from
       real command responses, same as before.

  These three peripherals (USART for UART, SPI hardware, TWI hardware)
  are all independent AVR hardware blocks - no conflict running all
  three at once, same reasoning as UART+SPI coexisting before.

  WIRING - all of it, combined:
    UART:
      Pin 0 (RX)  <- FPGA JA2 (UART TX)         direct wire
      Pin 1 (TX)  -> FPGA JA1 (UART RX)         THROUGH THE VOLTAGE DIVIDER
    SPI:
      Pin 13 (SCK)  <- FPGA JA3                 direct wire
      Pin 11 (MOSI) <- FPGA JA4                 direct wire
      Pin 12 (MISO) -> FPGA JA7                 THROUGH THE VOLTAGE DIVIDER
      Pin 10 (SS)   <- FPGA JA8                 direct wire
    I2C (NO divider needed - open-drain, shared 3.3V pull-ups instead):
      A4 (SDA) <-> FPGA JA9
      A5 (SCL) <-> FPGA JA10
      + external ~4.7k pull-ups from SDA to 3.3V and SCL to 3.3V
    Arduino GND <-> shared ground - required, as always.
*/

#include <Wire.h>
#include <avr/interrupt.h>

// ---- SPI slave state ----
volatile uint8_t spi_response_byte = 0xA5;
volatile uint8_t last_spi_received = 0x00;

// ---- I2C slave state ----
const uint8_t I2C_SLAVE_ADDRESS = 0x50;
volatile uint8_t last_i2c_received = 0x00;
volatile uint8_t i2c_response_byte = 0x68;

unsigned long last_send_time = 0;
const unsigned long SEND_INTERVAL_MS = 2000;
bool send_i2c_this_round = false;  // alternates each cycle

void setup() {
    Serial.begin(115200);
    pinMode(LED_BUILTIN, OUTPUT);

    // ---- SPI slave setup ----
    pinMode(MISO, OUTPUT);
    pinMode(MOSI, INPUT);
    pinMode(SCK, INPUT);
    pinMode(SS, INPUT);
    SPCR = (1 << SPE) | (1 << SPIE);
    SPDR = spi_response_byte;
    sei();

    // ---- I2C slave setup ----
    Wire.begin(I2C_SLAVE_ADDRESS);
    Wire.onReceive(onI2CReceive);
    Wire.onRequest(onI2CRequest);
}

ISR(SPI_STC_vect) {
    last_spi_received = SPDR;
    SPDR = spi_response_byte;
}

void onI2CReceive(int numBytes) {
    while (Wire.available() > 0) {
        last_i2c_received = Wire.read();
    }
}

void onI2CRequest() {
    Wire.write(i2c_response_byte);
}

void send_uart_byte(uint8_t b) {
    Serial.write(b);
}

// Reads one byte with a timeout, transparently consuming and blinking on
// any AYUSH marker message encountered along the way. Returns true if a
// real (non-marker) byte was obtained within the timeout.
bool read_byte_with_marker_handling(uint8_t &out_byte, unsigned long timeout_ms) {
    unsigned long wait_start = millis();
    while ((millis() - wait_start) < timeout_ms) {
        if (Serial.available() < 1) continue;
        uint8_t b = Serial.read();

        if (b == 0x02) {
            for (int i = 0; i < 5; i++) {
                unsigned long char_wait = millis();
                while (Serial.available() < 1 && (millis() - char_wait) < 200) {
                    // wait for each character
                }
                if (Serial.available() > 0) Serial.read();  // discard
            }
            digitalWrite(LED_BUILTIN, HIGH);
            delay(100);
            digitalWrite(LED_BUILTIN, LOW);
            wait_start = millis();  // reset timeout, keep waiting
            continue;
        }

        out_byte = b;
        return true;
    }
    return false;
}

void loop() {
    unsigned long now = millis();
    if (now - last_send_time >= SEND_INTERVAL_MS) {
        last_send_time = now;

        if (!send_i2c_this_round) {
            // ---- SPI command ----
            send_uart_byte(0b00000000);  // engine=SPI, length=1
            send_uart_byte(0x3C);

            uint8_t response;
            read_byte_with_marker_handling(response, 1000);
            (void)response;

            spi_response_byte++;
        } else {
            // ---- I2C command (write-then-read, register-read pattern) ----
            send_uart_byte(0b01100000);       // engine=I2C, R/W=1, length(read_count)=1
            send_uart_byte(I2C_SLAVE_ADDRESS); // device address
            send_uart_byte(1);                 // write_count = 1
            send_uart_byte(0x0F);              // arbitrary register address

            uint8_t read_byte, status_byte;
            bool got_read   = read_byte_with_marker_handling(read_byte, 1000);
            bool got_status = got_read && read_byte_with_marker_handling(status_byte, 1000);
            (void)got_status;

            i2c_response_byte++;
        }

        send_i2c_this_round = !send_i2c_this_round;  // alternate next time
    }
}
