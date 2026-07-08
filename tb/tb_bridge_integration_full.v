`timescale 1ns/1ps

module tb_bridge_integration_full;

    localparam CLK_FREQ  = 100_000_000;
    localparam BAUD_RATE = 115200;
    localparam SCLK_FREQ = 1_000_000;
    localparam SCL_FREQ  = 100_000;
    localparam BIT_PERIOD = 8681;

    reg clk;
    reg rst;
    reg host_tx_line;

    // ---- uart_rx (FPGA receiving from host) ----
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) rx_inst (
        .clk(clk), .rst(rst), .rx_line(host_tx_line),
        .rx_data(uart_rx_data), .rx_valid(uart_rx_valid), .framing_error()
    );

    // ---- dispatcher ----
    wire [7:0] uart_tx_data_w;
    wire       uart_tx_start_w;
    wire       uart_tx_busy;

    wire       spi_start, spi_cpol, spi_cpha;
    wire [4:0] spi_num_bytes;
    wire [7:0] spi_tx_data;
    wire       spi_byte_req;
    wire [7:0] spi_wr_data;
    wire       spi_byte_done;
    wire [7:0] spi_rx_data;
    wire       spi_byte_ack;
    wire       spi_done;

    wire       i2c_start;
    wire [6:0] i2c_dev_addr;
    wire [4:0] i2c_num_write_bytes, i2c_num_read_bytes;
    wire       i2c_byte_req;
    wire [7:0] i2c_wr_data;
    wire       i2c_read_byte_valid;
    wire [7:0] i2c_read_byte_data;
    wire       i2c_done, i2c_ack_error;

    dispatcher disp_inst (
        .clk(clk), .rst(rst),
        .rx_data(uart_rx_data), .rx_valid(uart_rx_valid),
        .uart_tx_data(uart_tx_data_w), .uart_tx_start(uart_tx_start_w), .uart_tx_busy(uart_tx_busy),
        .spi_start(spi_start), .spi_cpol(spi_cpol), .spi_cpha(spi_cpha), .spi_num_bytes(spi_num_bytes),
        .spi_tx_data(spi_tx_data), .spi_byte_req(spi_byte_req), .spi_wr_data(spi_wr_data),
        .spi_byte_done(spi_byte_done), .spi_rx_data(spi_rx_data), .spi_byte_ack(spi_byte_ack), .spi_done(spi_done),
        .i2c_start(i2c_start), .i2c_dev_addr(i2c_dev_addr),
        .i2c_num_write_bytes(i2c_num_write_bytes), .i2c_num_read_bytes(i2c_num_read_bytes),
        .i2c_byte_req(i2c_byte_req), .i2c_wr_data(i2c_wr_data),
        .i2c_read_byte_valid(i2c_read_byte_valid), .i2c_read_byte_data(i2c_read_byte_data),
        .i2c_done(i2c_done), .i2c_ack_error(i2c_ack_error)
    );

    // ---- spi_master v2 + mode-aware fake slave ----
    wire sclk, mosi, cs_n;
    reg  miso;

    spi_master #(.CLK_FREQ(CLK_FREQ), .SCLK_FREQ(SCLK_FREQ)) spi_inst (
        .clk(clk), .rst(rst), .start(spi_start), .cpol(spi_cpol), .cpha(spi_cpha),
        .num_bytes(spi_num_bytes), .tx_data(spi_tx_data),
        .byte_req(spi_byte_req), .wr_data(spi_wr_data),
        .byte_done(spi_byte_done), .rx_data(spi_rx_data), .byte_ack(spi_byte_ack),
        .busy(), .done(spi_done), .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    reg [7:0] slave_tx_data, slave_tx_shift, slave_rx_shift;
    reg [2:0] slave_bit_count;
    reg       slave_active;
    reg       prev_sclk_spi;

    always @(negedge cs_n) begin
        slave_active    <= 1'b1;
        slave_tx_shift  <= slave_tx_data;
        slave_bit_count <= 3'd0;
        prev_sclk_spi   <= 1'b0;   // mode 0 only used in this integration test (cpol=0)
        miso            <= slave_tx_data[7];
    end
    always @(posedge cs_n) slave_active <= 1'b0;

    always @(posedge clk) begin
        if (slave_active) begin
            prev_sclk_spi <= sclk;
            if (prev_sclk_spi !== sclk) begin
                if (sclk == 1'b1) begin
                    slave_rx_shift <= {slave_rx_shift[6:0], mosi};
                end else begin
                    if (slave_bit_count != 3'd7) begin
                        slave_tx_shift <= {slave_tx_shift[6:0], 1'b0};
                        miso           <= slave_tx_shift[6];
                    end
                    if (slave_bit_count == 3'd7) begin
                        slave_bit_count <= 3'd0;
                        slave_tx_shift  <= slave_tx_data;
                        miso            <= slave_tx_data[7];
                    end else begin
                        slave_bit_count <= slave_bit_count + 3'd1;
                    end
                end
            end
        end
    end

    // ---- i2c_master v2 + bidirectional fake slave ----
    wire i2c_sda_oe, i2c_scl_oe;
    wire sda_line, scl_line;
    reg  slave_sda_oe;

    assign sda_line = i2c_sda_oe ? 1'b0 : 1'bz;
    assign sda_line = slave_sda_oe ? 1'b0 : 1'bz;
    assign scl_line = i2c_scl_oe ? 1'b0 : 1'bz;
    assign (weak0, weak1) sda_line = 1'b1;
    assign (weak0, weak1) scl_line = 1'b1;

    i2c_master #(.CLK_FREQ(CLK_FREQ), .SCL_FREQ(SCL_FREQ)) i2c_inst (
        .clk(clk), .rst(rst), .start(i2c_start), .dev_addr(i2c_dev_addr),
        .num_write_bytes(i2c_num_write_bytes), .num_read_bytes(i2c_num_read_bytes),
        .byte_req(i2c_byte_req), .wr_data(i2c_wr_data),
        .read_byte_valid(i2c_read_byte_valid), .read_byte_data(i2c_read_byte_data),
        .busy(), .done(i2c_done), .ack_error(i2c_ack_error),
        .sda_oe(i2c_sda_oe), .sda_in(sda_line), .scl_oe(i2c_scl_oe)
    );

    reg [7:0] slave_shift;
    reg [3:0] bits_seen;
    reg       driving_ack;
    reg       mode;
    reg       is_first_byte;
    reg       pending_send_switch;
    reg [7:0] send_shift;
    reg [3:0] send_bits_done;
    reg [7:0] read_data_to_send [0:15];
    integer   send_data_index;
    reg [7:0] i2c_received_bytes [0:15];
    integer   i2c_received_count;
    reg       prev_scl_i2c, prev_sda_i2c;
    reg       transaction_active;

    initial begin
        slave_sda_oe = 1'b0; bits_seen = 4'd0; driving_ack = 1'b0; mode = 1'b0;
        is_first_byte = 1'b1; pending_send_switch = 1'b0; send_bits_done = 4'd0;
        send_data_index = 0; i2c_received_count = 0; transaction_active = 1'b0;
    end

    always @(posedge clk) begin
        prev_scl_i2c <= scl_line;
        prev_sda_i2c <= sda_line;
        if (prev_scl_i2c===1'b1 && scl_line===1'b1 && prev_sda_i2c===1'b1 && sda_line===1'b0) begin
            transaction_active <= 1'b1; bits_seen <= 4'd0; mode <= 1'b0;
            driving_ack <= 1'b0; is_first_byte <= 1'b1; pending_send_switch <= 1'b0;
        end else if (prev_scl_i2c===1'b1 && scl_line===1'b1 && prev_sda_i2c===1'b0 && sda_line===1'b1) begin
            transaction_active <= 1'b0; slave_sda_oe <= 1'b0;
        end else if (transaction_active && prev_scl_i2c===1'b0 && scl_line===1'b1) begin
            if (mode == 1'b0 && bits_seen < 4'd8) begin
                slave_shift <= {slave_shift[6:0], sda_line};
                bits_seen   <= bits_seen + 4'd1;
            end
        end else if (transaction_active && prev_scl_i2c===1'b1 && scl_line===1'b0) begin
            if (mode == 1'b0) begin
                if (bits_seen == 4'd8 && !driving_ack) begin
                    slave_sda_oe <= 1'b1; driving_ack <= 1'b1;
                    i2c_received_bytes[i2c_received_count] <= slave_shift;
                    i2c_received_count <= i2c_received_count + 1;
                    if (is_first_byte && slave_shift[0] == 1'b1)
                        pending_send_switch <= 1'b1;
                    is_first_byte <= 1'b0;
                end else if (driving_ack) begin
                    slave_sda_oe <= 1'b0; driving_ack <= 1'b0; bits_seen <= 4'd0;
                    if (pending_send_switch) begin
                        mode <= 1'b1; pending_send_switch <= 1'b0;
                        slave_sda_oe    <= read_data_to_send[send_data_index][7] ? 1'b0 : 1'b1;
                        send_shift      <= {read_data_to_send[send_data_index][6:0], 1'b0};
                        send_bits_done  <= 4'd1;
                        send_data_index <= send_data_index + 1;
                    end
                end
            end else begin
                if (send_bits_done < 4'd8) begin
                    slave_sda_oe   <= send_shift[7] ? 1'b0 : 1'b1;
                    send_shift     <= {send_shift[6:0], 1'b0};
                    send_bits_done <= send_bits_done + 4'd1;
                end else begin
                    slave_sda_oe    <= 1'b0;
                    send_bits_done  <= 4'd0;
                    send_shift      <= read_data_to_send[send_data_index];
                    send_data_index <= send_data_index + 1;
                end
            end
        end
    end

    // ---- uart_tx (FPGA sending back to host) + second uart_rx (host receiver) ----
    wire fpga_tx_line, uart_tx_busy_w;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) tx_inst (
        .clk(clk), .rst(rst), .tx_start(uart_tx_start_w), .tx_data(uart_tx_data_w),
        .tx_line(fpga_tx_line), .tx_busy(uart_tx_busy_w)
    );
    assign uart_tx_busy = uart_tx_busy_w;

    wire [7:0] host_rx_data;
    wire       host_rx_valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) host_rx_inst (
        .clk(clk), .rst(rst), .rx_line(fpga_tx_line),
        .rx_data(host_rx_data), .rx_valid(host_rx_valid), .framing_error()
    );

    always #5 clk = ~clk;

    reg [7:0] received_bytes [0:31];
    integer   received_count;

    always @(posedge clk) begin
        if (rst) received_count <= 0;
        else if (host_rx_valid) begin
            received_bytes[received_count] <= host_rx_data;
            received_count                 <= received_count + 1;
            $display("  [HOST] t=%0t received byte from FPGA: %h", $time, host_rx_data);
        end
    end

    task host_send_byte(input [7:0] data);
        integer i;
        begin
            $display("[HOST] t=%0t sending byte: %h", $time, data);
            host_tx_line = 1'b0;
            #(BIT_PERIOD);
            for (i = 0; i < 8; i = i + 1) begin
                host_tx_line = data[i];
                #(BIT_PERIOD);
            end
            host_tx_line = 1'b1;
            #(BIT_PERIOD);
        end
    endtask

    integer errors = 0;
    integer tests  = 0;

    initial begin
        clk           = 0;
        rst           = 1;
        host_tx_line  = 1'b1;
        miso          = 1'b0;
        slave_tx_data = 8'hA5;
        #50;
        rst = 0;
        #50;

        // ================= TEST 1: SPI single-byte (mode 0) =================
        $display("\n========== TEST 1: SPI single-byte ==========");
        received_count = 0;
        host_send_byte(8'b00_0_0_0000);  // SPI, cpol=0,cpha=0, length=1
        host_send_byte(8'h3C);
        #200000;

        tests = tests + 1;
        if (received_count != 1 || received_bytes[0] !== 8'hA5) begin
            $display("FAIL: SPI single-byte - got count=%0d byte=%h, expected 1/a5", received_count, received_bytes[0]);
            errors = errors + 1;
        end else begin
            $display("PASS: SPI single-byte correct (%h)", received_bytes[0]);
        end

        // ================= TEST 2: SPI multi-byte, continuous cs_n =================
        $display("\n========== TEST 2: SPI 3-byte, continuous cs_n ==========");
        received_count = 0;
        slave_tx_data  = 8'h99;
        host_send_byte(8'b00_0_0_0010);  // SPI, length=3
        host_send_byte(8'h11);
        host_send_byte(8'h22);
        host_send_byte(8'h33);
        #400000;

        tests = tests + 1;
        if (received_count != 3 || received_bytes[0] !== 8'h99 ||
            received_bytes[1] !== 8'h99 || received_bytes[2] !== 8'h99) begin
            $display("FAIL: SPI multi-byte - got %0d bytes: %h %h %h, expected 3x 99",
                      received_count, received_bytes[0], received_bytes[1], received_bytes[2]);
            errors = errors + 1;
        end else begin
            $display("PASS: SPI 3-byte transfer through full bridge correct (%h %h %h)",
                      received_bytes[0], received_bytes[1], received_bytes[2]);
        end

        // ================= TEST 3: I2C write-only (regression) =================
        $display("\n========== TEST 3: I2C write, device 0x50, 3 bytes ==========");
        received_count     = 0;
        i2c_received_count = 0;
        host_send_byte(8'b01_0_0_0010);  // I2C, R/W=0, length=3
        host_send_byte(8'h50);
        host_send_byte(8'hAA);
        host_send_byte(8'hBB);
        host_send_byte(8'hCC);
        #700000;

        tests = tests + 1;
        if (i2c_received_count != 4 || received_count != 1 || received_bytes[0] !== 8'h00) begin
            $display("FAIL: I2C write - slave saw %0d bytes, host got %0d status byte(s) = %h",
                      i2c_received_count, received_count, received_bytes[0]);
            errors = errors + 1;
        end else begin
            $display("PASS: I2C write-only through full bridge correct, status=%h", received_bytes[0]);
        end

        // ================= TEST 4: I2C combined write-then-read =================
        $display("\n========== TEST 4: I2C combined write-then-read (WHO_AM_I style) ==========");
        received_count      = 0;
        i2c_received_count  = 0;
        send_data_index     = 0;
        read_data_to_send[0] = 8'h68;   // canned WHO_AM_I response
        host_send_byte(8'b01_1_0_0000);  // I2C, R/W=1 (read-capable), length(read_count)=1
        host_send_byte(8'h68);           // device address
        host_send_byte(8'd1);            // write_count = 1 (register address follows)
        host_send_byte(8'h75);           // register address to write
        #900000;

        tests = tests + 1;
        if (received_count != 2) begin
            $display("FAIL: I2C combined - host got %0d bytes, expected 2 (1 read byte + 1 status)", received_count);
            errors = errors + 1;
        end else if (received_bytes[0] !== 8'h68) begin
            $display("FAIL: I2C combined - read byte = %h, expected 68", received_bytes[0]);
            errors = errors + 1;
        end else if (received_bytes[1] !== 8'h00) begin
            $display("FAIL: I2C combined - status byte = %h, expected 00", received_bytes[1]);
            errors = errors + 1;
        end else begin
            $display("PASS: I2C combined write-then-read through full bridge correct (read=%h, status=%h)",
                      received_bytes[0], received_bytes[1]);
        end

        $display("\n==========================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("%0d OF %0d TESTS FAILED", errors, tests);

        $finish;
    end

endmodule
