`timescale 1ns/1ps

module tb_uart_loopback;

    localparam CLK_FREQ   = 100_000_000;
    localparam BAUD_RATE  = 115200;
    localparam BIT_PERIOD = 8681;  // approx 1e9/115200 ns, rounded

    reg        clk;
    reg        rst;
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       framing_error;
    wire       tx_line;

    integer errors = 0;
    integer tests  = 0;

    // ---- DUT ----
    uart_loopback #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .tx_start      (tx_start),
        .tx_data       (tx_data),
        .tx_busy       (tx_busy),
        .rx_data       (rx_data),
        .rx_valid      (rx_valid),
        .framing_error (framing_error),
        .tx_line       (tx_line)
    );

    // ---- Clock: 100MHz -> 10ns period ----
    always #5 clk = ~clk;

    // ---- Background latch: catches rx_valid/framing_error even if they
    //      pulse while sequential test code is mid-delay elsewhere ----
    reg       latched_valid;
    reg [7:0] latched_data;
    reg       latched_framing_error;

    always @(posedge clk) begin
        if (rst) begin
            latched_valid         <= 1'b0;
            latched_data          <= 8'd0;
            latched_framing_error <= 1'b0;
        end else begin
            if (rx_valid) begin
                latched_valid <= 1'b1;
                latched_data  <= rx_data;
            end
            if (framing_error)
                latched_framing_error <= 1'b1;
        end
    end

    task clear_latch;
        begin
            latched_valid         = 1'b0;
            latched_framing_error = 1'b0;
        end
    endtask

    // ---- Task: wait until tx_busy clears before triggering a new send.
    //      (This is exactly the bug we hit in the cocotb version - a
    //      fixed delay is not a substitute for checking the real flag.) ----
    task wait_until_not_busy;
        begin
            while (tx_busy !== 1'b0)
                @(posedge clk);
        end
    endtask

    // ---- Task: trigger uart_tx to send one byte.
    //      IMPORTANT: tx_start uses NONBLOCKING assignment here. Using a
    //      blocking assignment to deassert tx_start at @(posedge clk) races
    //      the DUT's own always block, which is woken by the same edge -
    //      Verilog does not guarantee which one runs first. This caused an
    //      intermittent failure where the DUT sometimes saw tx_start=0 at
    //      the very edge it needed to sample tx_start=1. ----
    task send_byte(input [7:0] data);
        begin
            wait_until_not_busy;
            tx_data  <= data;
            tx_start <= 1'b1;
            @(posedge clk);
            tx_start <= 1'b0;
        end
    endtask

    // ---- Task: wait for the latch to catch a result, with a generous
    //      timeout (a full frame is 10 bit periods) ----
    task wait_for_result(input integer timeout_bits);
        integer waited;
        begin
            waited = 0;
            while (latched_valid !== 1'b1 && latched_framing_error !== 1'b1
                   && waited < (BIT_PERIOD * timeout_bits)) begin
                @(posedge clk);
                waited = waited + 10;
            end
        end
    endtask

    task check_byte(input [7:0] expected);
        begin
            tests = tests + 1;
            wait_for_result(14);
            if (latched_valid !== 1'b1) begin
                $display("FAIL: rx_valid never asserted for expected byte %h at time %0t", expected, $time);
                errors = errors + 1;
            end else if (latched_data !== expected) begin
                $display("FAIL: rx_data = %h, expected %h at time %0t", latched_data, expected, $time);
                errors = errors + 1;
            end else begin
                $display("PASS: received byte %h correctly at time %0t", expected, $time);
            end
        end
    endtask

    initial begin
        clk      = 0;
        rst      = 1;
        tx_start = 1'b0;
        tx_data  = 8'd0;
        #50;
        rst = 0;
        #50;

        // Test 1: known mixed-bit byte
        clear_latch;
        send_byte(8'h5A);
        check_byte(8'h5A);

        // Test 2: all zeros
        clear_latch;
        send_byte(8'h00);
        check_byte(8'h00);

        // Test 3: all ones
        clear_latch;
        send_byte(8'hFF);
        check_byte(8'hFF);

        // Test 4: back-to-back bytes, respecting tx_busy each time
        clear_latch;
        send_byte(8'h11);
        check_byte(8'h11);
        clear_latch;
        send_byte(8'h92);
        check_byte(8'h92);

        // ---- Summary ----
        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("%0d OF %0d TESTS FAILED", errors, tests);

        $finish;
    end

endmodule
