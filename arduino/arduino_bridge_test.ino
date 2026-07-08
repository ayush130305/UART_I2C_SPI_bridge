/*
  arduino_bridge_test.ino

  Dual role, matching the flow: Arduino(UART) -> FPGA -> SPI -> Arduino(SPI slave)

  1) Sends a UART command to the FPGA every 2 seconds, using the bridge's
     command byte format: [7:6]=engine(00=SPI), [5]=CPOL, [4]=CPHA,
     [3:0]=length-1. This sketch sends a single-byte SPI command
     (length=1) with a fixed data byte.

  2) Simultaneously acts as a real SPI SLAVE (NOT the normal SPI.h master
     mode) - the FPGA's spi_master drives SCK/MOSI/CS, and this Arduino
     responds on MISO, using the AVR's hardware SPI peripheral directly
     in slave mode.

  IMPORTANT HARDWARE NOTE: an Uno/Nano has only ONE hardware UART, and
  it's used here to talk to the FPGA (pins 0/1). This means you can't
  ALSO use Serial.println() for USB debug output without conflicting
  with the FPGA link - that's exactly why the FPGA's 7-segment display
  matters here: it's your visibility into what's happening, since you
  can't just open the Arduino Serial Monitor at the same time.
  (If you have an Arduino Mega, it has multiple hardware UARTs - you
  could dedicate Serial1 to the FPGA and keep Serial free for USB debug
  prints instead. Not done here to keep this portable to an Uno/Nano.)

  Wiring (Uno/Nano pin numbers):
    Pin 0 (RX)  <- FPGA JA2 (UART TX)         direct wire
    Pin 1 (TX)  -> FPGA JA1 (UART RX)         THROUGH THE VOLTAGE DIVIDER
    Pin 13 (SCK)  <- FPGA JA3 (SPI sclk)      direct wire
    Pin 11 (MOSI) <- FPGA JA4 (SPI mosi)      direct wire
    Pin 12 (MISO) -> FPGA JA7 (SPI miso)      THROUGH THE VOLTAGE DIVIDER
    Pin 10 (SS)   <- FPGA JA8 (SPI cs_n)      direct wire
*/

#include <avr/interrupt.h>

volatile uint8_t spi_response_byte = 0xA5;  // canned response the FPGA will read back
volatile uint8_t last_spi_received = 0x00;  // last byte the FPGA sent us

unsigned long last_send_time = 0;
const unsigned long SEND_INTERVAL_MS = 2000;

void setup() {
    // ---- UART to FPGA ----
    Serial.begin(115200);
    pinMode(LED_BUILTIN, OUTPUT);

    // ---- SPI slave setup (AVR hardware SPI peripheral, NOT SPI.h master mode) ----
    pinMode(MISO, OUTPUT);   // only MISO is driven by us; SCK/MOSI/SS are inputs (master-driven)
    pinMode(MOSI, INPUT);
    pinMode(SCK, INPUT);
    pinMode(SS, INPUT);      // SS MUST be an input for slave mode to work correctly

    SPCR = (1 << SPE) | (1 << SPIE);  // enable SPI, enable SPI interrupt, MSTR=0 -> slave mode
    SPDR = spi_response_byte;         // preload the first byte the master will read

    sei();  // enable global interrupts
}

// Fires once per completed SPI byte transfer (the FPGA's spi_master
// clocking one full byte in/out)
ISR(SPI_STC_vect) {
    last_spi_received = SPDR;   // byte the FPGA just sent us
    SPDR = spi_response_byte;   // queue our response for the FPGA's NEXT byte
}

void send_uart_byte(uint8_t b) {
    Serial.write(b);
}

void loop() {
    unsigned long now = millis();
    if (now - last_send_time >= SEND_INTERVAL_MS) {
        last_send_time = now;

        // Command byte: engine=SPI(00), CPOL=0, CPHA=0, length-1=0000 (1 byte)
        send_uart_byte(0b00000000);
        // The 1 data byte to send over SPI
        send_uart_byte(0x3C);

        // Wait for a byte over UART, with a timeout so a single missed
        // response can't permanently freeze the sketch. Since the
        // switch-triggered "AYUSH" message can arrive at any time on
        // this same link, we check for its marker byte (0x02) first and
        // consume it separately - otherwise it would get mistaken for
        // the real SPI response.
        uint8_t fpga_response = 0;
        bool got_response = false;
        unsigned long wait_start = millis();
        const unsigned long RESPONSE_TIMEOUT_MS = 1000;

        while (!got_response && (millis() - wait_start) < RESPONSE_TIMEOUT_MS) {
            if (Serial.available() < 1) {
                continue;  // keep checking, don't block forever
            }
            uint8_t b = Serial.read();

            if (b == 0x02) {
                // This is an unsolicited "AYUSH" message, not our SPI
                // response - consume the 5 following characters.
                for (int i = 0; i < 5; i++) {
                    unsigned long char_wait_start = millis();
                    while (Serial.available() < 1 && (millis() - char_wait_start) < 200) {
                        // wait for each character, with its own timeout
                    }
                    if (Serial.available() > 0) Serial.read();  // discard
                }
                // Blink the built-in LED once to confirm receipt, since
                // we can't print without disturbing the FPGA link
                digitalWrite(LED_BUILTIN, HIGH);
                delay(100);
                digitalWrite(LED_BUILTIN, LOW);
                wait_start = millis();  // reset the timeout window, keep waiting
                // loop back and keep waiting for the actual SPI response
            } else {
                fpga_response = b;
                got_response = true;
            }
        }
        (void)fpga_response;  // use this value however you like (e.g. drive an LED)
        // If got_response is false here, the round timed out - the sketch
        // will simply try again on the next 2-second cycle rather than
        // hanging forever.

        // Change what we'll respond with next time, so each round is visibly different
        spi_response_byte++;
    }
}
