// basys3_top.v
// Real hardware top-level: wraps bridge_top (the UART/SPI/I2C bridge)
// and adds the onboard 7-segment display, showing:
//   - low 2 digits  : last byte received from the host over UART
//   - high 2 digits : last byte sent back to the host over UART
// This is what actually gets synthesized and flashed - bridge_top.v
// itself stays simulation-friendly/reusable, this file adds the
// board-specific display wiring on top.

module basys3_top (
    input  wire clk,
    input  wire btnC,        // center button = reset
    input  wire sw0,         // switch: toggle to send "AYUSH" over UART

    input  wire ja1,         // UART RX in  (from Arduino TX, via divider)
    output wire ja2,         // UART TX out (to Arduino RX)
    output wire ja3,         // SPI sclk
    output wire ja4,         // SPI mosi
    input  wire ja7,         // SPI miso (from Arduino, via divider)
    output wire ja8,         // SPI cs_n

    inout  wire ja9,         // I2C SDA (open-drain, shared 3.3V pull-up, no divider needed)
    inout  wire ja10,        // I2C SCL (open-drain, shared 3.3V pull-up, no divider needed)

    output wire [6:0] seg,
    output wire       dp,
    output wire [3:0] an
);

    wire rst = btnC;

    // ---- Capture last bytes seen, for the display ----
    wire [7:0] uart_rx_data_probe;
    wire       uart_rx_valid_probe;
    wire [7:0] uart_tx_data_probe;
    wire       uart_tx_start_probe;

    reg [7:0] last_rx_byte;
    reg [7:0] last_tx_byte;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            last_rx_byte <= 8'd0;
            last_tx_byte <= 8'd0;
        end else begin
            if (uart_rx_valid_probe)
                last_rx_byte <= uart_rx_data_probe;
            if (uart_tx_start_probe)
                last_tx_byte <= uart_tx_data_probe;
        end
    end

    // I2C bus needs true open-drain at the physical pin level - modeled
    // via a tri-state buffer here (the internal modules only ever deal
    // in oe/driven-value, per our established convention). Not wired to
    // an external port in this Arduino-SPI-only setup, but kept
    // internal so bridge_top's I2C engine still has somewhere to go.
    wire i2c_sda_oe_w, i2c_scl_oe_w;

    wire bridge_tx_line;   // bridge_top's own UART TX output - now muxed onto ja2 below
    wire i2c_sda_in_w;

    bridge_top #(
        .CLK_FREQ(100_000_000),
        .BAUD_RATE(115200),
        .SCLK_FREQ(1_000_000),
        .SCL_FREQ(100_000)
    ) bridge_inst (
        .clk(clk),
        .rst(rst),
        .host_tx_line(ja1),
        .fpga_tx_line(bridge_tx_line),
        .sclk(ja3),
        .mosi(ja4),
        .miso(ja7),
        .cs_n(ja8),
        .i2c_sda_oe(i2c_sda_oe_w),
        .i2c_sda_in(i2c_sda_in_w),
        .i2c_scl_oe(i2c_scl_oe_w)
    );

    // ---- Real physical open-drain tri-state buffers for I2C.
    //      Standard Verilog idiom: assigning 1'bz when not driving
    //      synthesizes to an actual IOBUF on the FPGA pin. Both sides of
    //      the bus (FPGA and Arduino) only ever pull LOW or release -
    //      the external 3.3V pull-up resistors do the rest. No clock
    //      stretching support (matches i2c_master.v's current design). ----
    assign ja9      = i2c_sda_oe_w ? 1'b0 : 1'bz;
    assign i2c_sda_in_w = ja9;
    assign ja10     = i2c_scl_oe_w ? 1'b0 : 1'bz;

    // ---- Switch-triggered "AYUSH" string sender ----
    // NOTE: shares the physical UART TX pin (ja2) with the main bridge
    // via a simple PRIORITY mux, not a full arbiter. If the switch is
    // toggled at the exact same instant the bridge is sending a real
    // SPI/I2C response, one of the two messages can get corrupted.
    // Acceptable for a manually-triggered demo feature; a fully
    // arbitrated shared-UART design would need more work than this.
    wire switch_edge_pulse;
    wire [7:0] switch_tx_data;
    wire       switch_tx_start;
    wire       switch_tx_busy;
    wire       switch_tx_line;

    debounce #(.CLK_FREQ(100_000_000), .STABLE_MS(10)) db_inst (
        .clk(clk),
        .rst(rst),
        .sw_in(sw0),
        .edge_pulse(switch_edge_pulse)
    );

    switch_string_sender sender_inst (
        .clk(clk),
        .rst(rst),
        .sw_edge_pulse(switch_edge_pulse),
        .tx_data(switch_tx_data),
        .tx_start(switch_tx_start),
        .tx_busy(switch_tx_busy)
    );

    uart_tx #(.CLK_FREQ(100_000_000), .BAUD_RATE(115200)) switch_tx_inst (
        .clk(clk),
        .rst(rst),
        .tx_start(switch_tx_start),
        .tx_data(switch_tx_data),
        .tx_line(switch_tx_line),
        .tx_busy(switch_tx_busy)
    );

    // Priority mux: while the switch sender is actively transmitting,
    // its output wins; otherwise the main bridge's UART TX drives ja2.
    assign ja2 = switch_tx_busy ? switch_tx_line : bridge_tx_line;

    // Tap the probe signals via hierarchical reference for the display
    // (simplest way to expose internal bridge_top signals without
    // changing bridge_top's own port list)
    assign uart_rx_data_probe  = bridge_inst.uart_rx_data;
    assign uart_rx_valid_probe = bridge_inst.uart_rx_valid;
    assign uart_tx_data_probe  = bridge_inst.uart_tx_data_w;
    assign uart_tx_start_probe = bridge_inst.uart_tx_start_w;

    seven_seg_driver #(.CLK_FREQ(100_000_000), .REFRESH_HZ(1000)) seg_inst (
        .clk(clk),
        .rst(rst),
        .value({last_tx_byte, last_rx_byte}),
        .seg(seg),
        .dp(dp),
        .an(an)
    );

endmodule
