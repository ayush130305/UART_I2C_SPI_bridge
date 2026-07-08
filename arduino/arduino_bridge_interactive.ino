/*
  arduino_bridge_interactive.ino

  Uno-specific fix: the Uno has only ONE hardware UART, which Serial
  Monitor also uses. Since we want BOTH "type a byte in Serial Monitor"
  AND "talk to the FPGA over UART" at the same time, this uses
  SoftwareSerial on two spare pins for the FPGA link instead, leaving
  hardware Serial (pins 0/1) free for the USB Serial Monitor.

  Wiring change from before:
    FPGA JA1 (UART RX)  <- Arduino pin 9 (SoftwareSerial TX), THROUGH DIVIDER
    FPGA JA2 (UART TX)  -> Arduino pin 8 (SoftwareSerial RX), direct wire
    SPI pins (10/11/12/13) - UNCHANGED from before, still hardware SPI

  Usage: open Serial Monitor at 9600 baud (matches hardware Serial.begin
  below - this is just for typing/reading, separate from the
  SoftwareSerial FPGA link's own 9600 baud). Type a hex byte value
  (0-255) and press Enter to send an SPI single-byte command to the
  FPGA; the FPGA's SPI response byte will be echoed back here.
*/

#include <SoftwareSerial.h>
#include <avr/interrupt.h>

const int FPGA_RX_PIN = 8;   // Arduino reads FPGA's UART TX here
const int FPGA_TX_PIN = 9;   // Arduino drives FPGA's UART RX here (through divider)

SoftwareSerial fpgaLink(FPGA_RX_PIN, FPGA_TX_PIN);

volatile uint8_t spi_response_byte = 0xA5;
volatile uint8_t last_spi_received = 0x00;

void setup() {
    Serial.begin(9600);       // USB Serial Monitor
    fpgaLink.begin(9600);     // link to the FPGA

    // ---- SPI slave setup (unchanged from before) ----
    pinMode(MISO, OUTPUT);
    pinMode(MOSI, INPUT);
    pinMode(SCK, INPUT);
    pinMode(SS, INPUT);

    SPCR = (1 << SPE) | (1 << SPIE);
    SPDR = spi_response_byte;

    sei();

    Serial.println(F("Ready. Type a byte value (0-255) and press Enter to send to the FPGA."));
}

ISR(SPI_STC_vect) {
    last_spi_received = SPDR;
    SPDR = spi_response_byte;
}

void loop() {
    // ---- Read a typed value from Serial Monitor (accepts "0xNN", "NN" hex, or plain decimal) ----
    if (Serial.available() > 0) {
        String input = Serial.readStringUntil('\n');
        input.trim();

        if (input.length() > 0) {
            uint8_t data_byte = (uint8_t) strtol(input.c_str(), NULL, 0);
            // base 0 in strtol auto-detects: "0x1F" -> hex, "31" -> decimal

            Serial.print(F("Sending to FPGA: 0x"));
            Serial.println(data_byte, HEX);

            // Command byte: engine=SPI(00), CPOL=0, CPHA=0, length-1=0000 (1 byte)
            fpgaLink.write((uint8_t)0b00000000);
            fpgaLink.write(data_byte);

            // Wait for the FPGA's response, but first check for the AYUSH
            // marker byte (0x02) - since fpgaLink is on separate pins from
            // Serial here, we can safely print it when it arrives.
            unsigned long start_wait = millis();
            bool got_response = false;
            uint8_t fpga_response = 0;

            while (!got_response && (millis() - start_wait) < 2000) {
                if (fpgaLink.available() < 1) continue;
                uint8_t b = fpgaLink.read();

                if (b == 0x02) {
                   //AYUSH
                    char msg[6];
                    for (int i = 0; i < 5; i++) {
                        unsigned long char_wait = millis();
                        while (fpgaLink.available() < 1 && (millis() - char_wait) < 200) {
                            // wait for each character
                        }
                        msg[i] = (fpgaLink.available() > 0) ? fpgaLink.read() : '?';
                    }
                    msg[5] = '\0';
                    Serial.print(F("FPGA switch-triggered message: "));
                    Serial.println(msg);
                    start_wait = millis();  // reset timeout, keep waiting for the real response
                } else {
                    fpga_response = b;
                    got_response = true;
                }
            }

            if (got_response) {
                Serial.print(F("FPGA responded: 0x"));
                Serial.println(fpga_response, HEX);
            } else {
                Serial.println(F("No response from FPGA (timed out) - check wiring/power."));
            }
        }
        // Clear any leftover newline/whitespace
        while (Serial.available() > 0) Serial.read();
    }
}
