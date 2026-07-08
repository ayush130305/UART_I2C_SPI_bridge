`timescale 1ns/1ps

module tb_uart_rx;

    // Parameters must match the DUT instantiation below
    localparam CLK_FREQ   = 100_000_000;
    localparam BAUD_RATE  = 115200;
    localparam BIT_PERIOD = 8681;  // approx 1e9/115200 ns, rounded

    reg        clk;
    reg        rst;
    reg        rx_line;
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       framing_error;

    integer errors = 0;
    integer tests  = 0;

    // ---- Background latch: captures one-cycle pulses even while a
    //      send_byte task is still mid-delay and not yet polling ----
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

    // ---- DUT ----
    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .rx_line       (rx_line),
        .rx_data       (rx_data),
        .rx_valid      (rx_valid),
        .framing_error (framing_error)
    );

    // ---- Clock: 100MHz -> 10ns period -> 5ns half period ----
    always #5 clk = ~clk;

    // ---- Task: bit-bang one well-formed UART byte onto rx_line ----
    task send_byte(input [7:0] data);
        integer i;
        begin
            rx_line = 1'b0;             // start bit
            #(BIT_PERIOD);
            for (i = 0; i < 8; i = i + 1) begin
                rx_line = data[i];      // LSB first
                #(BIT_PERIOD);
            end
            rx_line = 1'b1;             // stop bit
            #(BIT_PERIOD);
        end
    endtask

    // ---- Task: bit-bang a byte with a deliberately bad (LOW) stop bit ----
    task send_byte_bad_stop(input [7:0] data);
        integer i;
        begin
            rx_line = 1'b0;
            #(BIT_PERIOD);
            for (i = 0; i < 8; i = i + 1) begin
                rx_line = data[i];
                #(BIT_PERIOD);
            end
            rx_line = 1'b0;             // bad: should be HIGH
            #(BIT_PERIOD);
            rx_line = 1'b1;             // release line back to idle
        end
    endtask

    // ---- Task: clear the latch before starting a new send ----
    task clear_latch;
        begin
            latched_valid         = 1'b0;
            latched_framing_error = 1'b0;
        end
    endtask

    // ---- Task: check the latched result against an expected byte ----
    task check_byte(input [7:0] expected);
        begin
            tests = tests + 1;
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
        clk     = 0;
        rst     = 1;
        rx_line = 1'b1;  // idle HIGH
        #50;
        rst = 0;
        #50;

        // Test 1: known mixed-bit byte
        clear_latch;
        send_byte(8'hA5);
        #(BIT_PERIOD);  // let the tail end of stop-bit processing settle
        check_byte(8'hA5);
        #(BIT_PERIOD*2);

        // Test 2: all zeros
        clear_latch;
        send_byte(8'h00);
        #(BIT_PERIOD);
        check_byte(8'h00);
        #(BIT_PERIOD*2);

        // Test 3: all ones
        clear_latch;
        send_byte(8'hFF);
        #(BIT_PERIOD);
        check_byte(8'hFF);
        #(BIT_PERIOD*2);

        // Test 4: framing error (bad stop bit)
        tests = tests + 1;
        clear_latch;
        send_byte_bad_stop(8'h3C);
        #(BIT_PERIOD);
        if (latched_framing_error !== 1'b1) begin
            $display("FAIL: framing_error not asserted on bad stop bit at time %0t", $time);
            errors = errors + 1;
        end else begin
            $display("PASS: framing_error correctly asserted at time %0t", $time);
        end
        #(BIT_PERIOD*2);

        // ---- Summary ----
        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("%0d OF %0d TESTS FAILED", errors, tests);

        $finish;
    end

endmodule
