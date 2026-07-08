## basys3_top.xdc
## Pin assignments verified against Digilent's official Basys-3-Master.xdc
## (https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc)

## Clock signal (100MHz onboard oscillator)
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## Reset (center button)
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports btnC]

## Switch 0 - toggle to trigger "AYUSH" string send
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports sw0]

## Pmod Header JA - UART + SPI to Arduino
## JA1 = ja1 (UART RX, FPGA input - from Arduino TX through a voltage divider)
## JA2 = ja2 (UART TX, FPGA output - to Arduino RX directly)
## JA3 = ja3 (SPI sclk, FPGA output)
## JA4 = ja4 (SPI mosi, FPGA output)
## JA7 = ja7 (SPI miso, FPGA input - from Arduino through a voltage divider)
## JA8 = ja8 (SPI cs_n, FPGA output)
set_property -dict { PACKAGE_PIN J1 IOSTANDARD LVCMOS33 } [get_ports ja1]
set_property -dict { PACKAGE_PIN L2 IOSTANDARD LVCMOS33 } [get_ports ja2]
set_property -dict { PACKAGE_PIN J2 IOSTANDARD LVCMOS33 } [get_ports ja3]
set_property -dict { PACKAGE_PIN G2 IOSTANDARD LVCMOS33 } [get_ports ja4]
set_property -dict { PACKAGE_PIN H1 IOSTANDARD LVCMOS33 } [get_ports ja7]
set_property -dict { PACKAGE_PIN K2 IOSTANDARD LVCMOS33 } [get_ports ja8]

## JA9/JA10 = I2C SDA/SCL (open-drain, shared 3.3V pull-up, no divider needed)
set_property -dict { PACKAGE_PIN H2 IOSTANDARD LVCMOS33 } [get_ports ja9]
set_property -dict { PACKAGE_PIN G3 IOSTANDARD LVCMOS33 } [get_ports ja10]

## 7 Segment Display
set_property -dict { PACKAGE_PIN W7 IOSTANDARD LVCMOS33 } [get_ports {seg[0]}]
set_property -dict { PACKAGE_PIN W6 IOSTANDARD LVCMOS33 } [get_ports {seg[1]}]
set_property -dict { PACKAGE_PIN U8 IOSTANDARD LVCMOS33 } [get_ports {seg[2]}]
set_property -dict { PACKAGE_PIN V8 IOSTANDARD LVCMOS33 } [get_ports {seg[3]}]
set_property -dict { PACKAGE_PIN U5 IOSTANDARD LVCMOS33 } [get_ports {seg[4]}]
set_property -dict { PACKAGE_PIN V5 IOSTANDARD LVCMOS33 } [get_ports {seg[5]}]
set_property -dict { PACKAGE_PIN U7 IOSTANDARD LVCMOS33 } [get_ports {seg[6]}]
set_property -dict { PACKAGE_PIN V7 IOSTANDARD LVCMOS33 } [get_ports dp]
set_property -dict { PACKAGE_PIN U2 IOSTANDARD LVCMOS33 } [get_ports {an[0]}]
set_property -dict { PACKAGE_PIN U4 IOSTANDARD LVCMOS33 } [get_ports {an[1]}]
set_property -dict { PACKAGE_PIN V4 IOSTANDARD LVCMOS33 } [get_ports {an[2]}]
set_property -dict { PACKAGE_PIN W4 IOSTANDARD LVCMOS33 } [get_ports {an[3]}]

## Configuration options (standard, from Digilent's master XDC)
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
