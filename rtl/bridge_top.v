// bridge_top.v
// Pure structural wrapper: wires uart_rx -> dispatcher -> spi_master /
// i2c_master -> uart_tx together. No test stimulus here - that lives in
// the cocotb Python testbench instead. This exists purely so cocotb has
// a single toplevel module to attach to (mirrors what tb_bridge_
// integration_full.v did internally, minus the testbench logic).

module bridge_top #(
    parameter integer CLK_FREQ  = 100_000_000,
    parameter integer BAUD_RATE = 115200,
    parameter integer SCLK_FREQ = 1_000_000,
    parameter integer SCL_FREQ  = 100_000
)(
    input  wire clk,
    input  wire rst,

    // ---- host-facing UART ----
    input  wire host_tx_line,   // host PC -> FPGA
    output wire fpga_tx_line,   // FPGA -> host PC

    // ---- SPI bus (external peripheral side) ----
    output wire sclk,
    output wire mosi,
    input  wire miso,
    output wire cs_n,

    // ---- I2C bus (external peripheral side, open-drain modeled explicitly) ----
    output wire i2c_sda_oe,
    input  wire i2c_sda_in,
    output wire i2c_scl_oe
);

    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) rx_inst (
        .clk(clk), .rst(rst), .rx_line(host_tx_line),
        .rx_data(uart_rx_data), .rx_valid(uart_rx_valid), .framing_error()
    );

    wire [7:0] uart_tx_data_w;
    wire       uart_tx_start_w;
    wire       uart_tx_busy_w;

    wire       spi_start_w, spi_cpol_w, spi_cpha_w;
    wire [4:0] spi_num_bytes_w;
    wire [7:0] spi_tx_data_w;
    wire       spi_byte_req_w;
    wire [7:0] spi_wr_data_w;
    wire       spi_byte_done_w;
    wire [7:0] spi_rx_data_w;
    wire       spi_byte_ack_w;
    wire       spi_done_w;

    wire       i2c_start_w;
    wire [6:0] i2c_dev_addr_w;
    wire [4:0] i2c_num_write_bytes_w, i2c_num_read_bytes_w;
    wire       i2c_byte_req_w;
    wire [7:0] i2c_wr_data_w;
    wire       i2c_read_byte_valid_w;
    wire [7:0] i2c_read_byte_data_w;
    wire       i2c_done_w, i2c_ack_error_w;

    dispatcher disp_inst (
        .clk(clk), .rst(rst),
        .rx_data(uart_rx_data), .rx_valid(uart_rx_valid),
        .uart_tx_data(uart_tx_data_w), .uart_tx_start(uart_tx_start_w), .uart_tx_busy(uart_tx_busy_w),
        .spi_start(spi_start_w), .spi_cpol(spi_cpol_w), .spi_cpha(spi_cpha_w), .spi_num_bytes(spi_num_bytes_w),
        .spi_tx_data(spi_tx_data_w), .spi_byte_req(spi_byte_req_w), .spi_wr_data(spi_wr_data_w),
        .spi_byte_done(spi_byte_done_w), .spi_rx_data(spi_rx_data_w), .spi_byte_ack(spi_byte_ack_w), .spi_done(spi_done_w),
        .i2c_start(i2c_start_w), .i2c_dev_addr(i2c_dev_addr_w),
        .i2c_num_write_bytes(i2c_num_write_bytes_w), .i2c_num_read_bytes(i2c_num_read_bytes_w),
        .i2c_byte_req(i2c_byte_req_w), .i2c_wr_data(i2c_wr_data_w),
        .i2c_read_byte_valid(i2c_read_byte_valid_w), .i2c_read_byte_data(i2c_read_byte_data_w),
        .i2c_done(i2c_done_w), .i2c_ack_error(i2c_ack_error_w)
    );

    spi_master #(.CLK_FREQ(CLK_FREQ), .SCLK_FREQ(SCLK_FREQ)) spi_inst (
        .clk(clk), .rst(rst), .start(spi_start_w), .cpol(spi_cpol_w), .cpha(spi_cpha_w),
        .num_bytes(spi_num_bytes_w), .tx_data(spi_tx_data_w),
        .byte_req(spi_byte_req_w), .wr_data(spi_wr_data_w),
        .byte_done(spi_byte_done_w), .rx_data(spi_rx_data_w), .byte_ack(spi_byte_ack_w),
        .busy(), .done(spi_done_w), .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    i2c_master #(.CLK_FREQ(CLK_FREQ), .SCL_FREQ(SCL_FREQ)) i2c_inst (
        .clk(clk), .rst(rst), .start(i2c_start_w), .dev_addr(i2c_dev_addr_w),
        .num_write_bytes(i2c_num_write_bytes_w), .num_read_bytes(i2c_num_read_bytes_w),
        .byte_req(i2c_byte_req_w), .wr_data(i2c_wr_data_w),
        .read_byte_valid(i2c_read_byte_valid_w), .read_byte_data(i2c_read_byte_data_w),
        .busy(), .done(i2c_done_w), .ack_error(i2c_ack_error_w),
        .sda_oe(i2c_sda_oe), .sda_in(i2c_sda_in), .scl_oe(i2c_scl_oe)
    );

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) tx_inst (
        .clk(clk), .rst(rst), .tx_start(uart_tx_start_w), .tx_data(uart_tx_data_w),
        .tx_line(fpga_tx_line), .tx_busy(uart_tx_busy_w)
    );

endmodule
