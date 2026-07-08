// uart_loopback.v
// Wires uart_tx's output directly into uart_rx's input.
// This lets us prove TX and RX genuinely agree on timing/format with
// each other, not just against a synthetic testbench checker.

module uart_loopback #(
    parameter integer CLK_FREQ  = 100_000_000,
    parameter integer BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst,

    // TX side (drive these to send a byte)
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    output wire        tx_busy,

    // RX side (observe these to confirm the byte arrived)
    output wire [7:0] rx_data,
    output wire        rx_valid,
    output wire        framing_error,

    // exposed for waveform inspection
    output wire        tx_line
);

    uart_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) tx_inst (
        .clk      (clk),
        .rst      (rst),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx_line  (tx_line),
        .tx_busy  (tx_busy)
    );

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) rx_inst (
        .clk           (clk),
        .rst           (rst),
        .rx_line       (tx_line),   // <-- the actual loopback wire
        .rx_data       (rx_data),
        .rx_valid      (rx_valid),
        .framing_error (framing_error)
    );

endmodule
