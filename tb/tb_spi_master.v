`timescale 1ns/1ps

module tb_spi_master;

    localparam CLK_FREQ  = 100_000_000;
    localparam SCLK_FREQ = 1_000_000;

    reg        clk;
    reg        rst;
    reg        start;
    reg        cpol, cpha;
    reg  [4:0] num_bytes;
    reg  [7:0] tx_data;
    wire       byte_req;
    reg  [7:0] wr_data;
    wire       byte_done;
    wire [7:0] rx_data;
    reg        byte_ack;
    wire       busy;
    wire       done;
    wire       sclk, mosi, cs_n;
    reg        miso;

    integer errors = 0;
    integer tests  = 0;

    spi_master #(.CLK_FREQ(CLK_FREQ), .SCLK_FREQ(SCLK_FREQ)) dut (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .cpol      (cpol),
        .cpha      (cpha),
        .num_bytes (num_bytes),
        .tx_data   (tx_data),
        .byte_req  (byte_req),
        .wr_data   (wr_data),
        .byte_done (byte_done),
        .rx_data   (rx_data),
        .byte_ack  (byte_ack),
        .busy      (busy),
        .done      (done),
        .sclk      (sclk),
        .mosi      (mosi),
        .miso      (miso),
        .cs_n      (cs_n)
    );

    always #5 clk = ~clk;

    // ---- write data source (matches i2c_master testbench pattern) ----
    reg [7:0] data_to_send [0:15];
    integer   send_index;

    always @(*) wr_data = data_to_send[send_index];

    always @(posedge clk or posedge rst) begin
        if (rst) send_index <= 0;
        else if (byte_req) send_index <= send_index + 1;
    end

    // ---- captured results ----
    reg [7:0] captured_bytes [0:15];
    integer   captured_count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            captured_count <= 0;
            byte_ack       <= 1'b0;
        end else begin
            byte_ack <= 1'b0;
            if (byte_done) begin
                captured_bytes[captured_count] <= rx_data;
                captured_count                  <= captured_count + 1;
                byte_ack                        <= 1'b1;
            end
        end
    end

    // ---- cs_n continuity check: latches HIGH if cs_n ever glitches
    //      high while the master still reports busy ----
    reg cs_glitch_detected;
    always @(posedge clk or posedge rst) begin
        if (rst) cs_glitch_detected <= 1'b0;
        else if (busy && cs_n) cs_glitch_detected <= 1'b1;
    end

    // ---- Generic mode-aware slave model: mirrors the master's own
    //      leading/trailing edge convention (both sides of true SPI
    //      full-duplex must agree on which edge is sample vs setup). ----
    reg [7:0] slave_tx_data;
    reg [7:0] slave_tx_shift;
    reg [7:0] slave_rx_shift;
    reg [2:0] slave_bit_count;
    reg       prev_sclk;
    reg       slave_active;

    always @(negedge cs_n) begin
        slave_active    <= 1'b1;
        slave_tx_shift  <= slave_tx_data;
        slave_bit_count <= 3'd0;
        prev_sclk       <= cpol;
        if (cpha == 1'b0)
            miso <= slave_tx_data[7];   // pre-tick setup, same reasoning as master's
    end

    always @(posedge cs_n) begin
        slave_active <= 1'b0;
    end

    always @(posedge clk) begin
        if (slave_active) begin
            prev_sclk <= sclk;
            if (prev_sclk !== sclk) begin
                // an edge just occurred on sclk
                if (sclk != cpol) begin
                    // leading edge
                    if (!cpha) begin
                        slave_rx_shift <= {slave_rx_shift[6:0], mosi};
                    end else begin
                        miso           <= slave_tx_shift[7];
                        slave_tx_shift <= {slave_tx_shift[6:0], 1'b0};
                    end
                end else begin
                    // trailing edge
                    if (!cpha) begin
                        if (slave_bit_count != 3'd7) begin
                            slave_tx_shift <= {slave_tx_shift[6:0], 1'b0};
                            miso           <= slave_tx_shift[6];
                        end
                    end else begin
                        slave_rx_shift <= {slave_rx_shift[6:0], mosi};
                    end

                    if (slave_bit_count == 3'd7) begin
                        // byte complete - record it, prep next canned response.
                        // Same CPHA=1 fix as the master: this edge is also
                        // the last bit's sample edge, so slave_rx_shift's
                        // pre-edge value is missing that final bit.
                        received_bytes[received_count] <= cpha ? {slave_rx_shift[6:0], mosi} : slave_rx_shift;
                        received_count                   <= received_count + 1;
                        slave_bit_count <= 3'd0;
                        slave_tx_shift  <= slave_tx_data;  // next byte's canned response
                        if (cpha == 1'b0)
                            miso <= slave_tx_data[7];
                    end else begin
                        slave_bit_count <= slave_bit_count + 3'd1;
                    end
                end
            end
        end
    end

    reg [7:0] received_bytes [0:15];
    integer   received_count;

    task do_transfer(input integer n, input [1:0] mode);
        begin
            @(negedge clk);
            send_index     = 1;   // [0] already goes out directly via tx_data below
            captured_count = 0;
            received_count = 0;
            cpol      <= mode[1];
            cpha      <= mode[0];
            num_bytes <= n[4:0];
            tx_data   <= data_to_send[0];
            start     <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
        end
    endtask

    task wait_for_done(input integer timeout_cycles);
        integer waited;
        begin
            waited = 0;
            while (!done && waited < timeout_cycles) begin
                @(posedge clk);
                waited = waited + 1;
            end
        end
    endtask

    initial begin
        clk       = 0;
        rst       = 1;
        start     = 1'b0;
        cpol      = 1'b0;
        cpha      = 1'b0;
        num_bytes = 5'd0;
        tx_data   = 8'd0;
        miso      = 1'b0;
        byte_ack  = 1'b0;
        slave_tx_data = 8'hA5;
        #50;
        rst = 0;
        #50;

        // ================= Test each of the 4 modes, single byte =================
        for (integer m = 0; m < 4; m = m + 1) begin
            data_to_send[0] = 8'h3C;
            slave_tx_data   = 8'hA5;
            do_transfer(1, m[1:0]);
            wait_for_done(3000);

            tests = tests + 1;
            if (captured_count != 1 || captured_bytes[0] !== 8'hA5) begin
                $display("FAIL: mode %0d single-byte - captured count=%0d data=%h, expected 1/a5",
                          m, captured_count, captured_bytes[0]);
                errors = errors + 1;
            end else if (received_count != 1 || received_bytes[0] !== 8'h3C) begin
                $display("FAIL: mode %0d single-byte - slave received count=%0d data=%h, expected 1/3c",
                          m, received_count, received_bytes[0]);
                errors = errors + 1;
            end else begin
                $display("PASS: mode %0d single-byte transfer correct (sent 3c, got a5 back)", m);
            end
            #2000;
        end

        // ================= Multi-byte, continuous cs_n, mode 0 =================
        data_to_send[0] = 8'h11;
        data_to_send[1] = 8'h22;
        data_to_send[2] = 8'h33;
        slave_tx_data   = 8'h99;   // slave sends same canned byte each time (simplification)
        do_transfer(3, 2'b00);
        wait_for_done(6000);

        tests = tests + 1;
        if (cs_glitch_detected) begin
            $display("FAIL: cs_n glitched HIGH mid-transaction (should stay low for all 3 bytes)");
            errors = errors + 1;
        end else if (captured_count != 3) begin
            $display("FAIL: multi-byte - captured %0d bytes, expected 3", captured_count);
            errors = errors + 1;
        end else if (received_count != 3 || received_bytes[0] !== 8'h11 ||
                     received_bytes[1] !== 8'h22 || received_bytes[2] !== 8'h33) begin
            $display("FAIL: multi-byte - slave received %h %h %h, expected 11 22 33",
                      received_bytes[0], received_bytes[1], received_bytes[2]);
            errors = errors + 1;
        end else begin
            $display("PASS: multi-byte transfer (3 bytes) with continuous cs_n - no glitches, all bytes correct");
        end

        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("%0d OF %0d TESTS FAILED", errors, tests);

        $finish;
    end

endmodule
