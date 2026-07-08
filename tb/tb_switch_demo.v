`timescale 1ns/1ps

module tb_switch_demo;

    localparam CLK_FREQ  = 100_000_000;
    localparam BAUD_RATE = 115200;
    localparam BIT_PERIOD = 8681;

    reg clk, rst;
    reg sw_in;

    wire edge_pulse;
    wire [7:0] tx_data;
    wire       tx_start;
    wire       tx_busy;
    wire       tx_line;

    // Use a much shorter debounce time for simulation speed (real hardware would use ~10ms)
    debounce #(.CLK_FREQ(CLK_FREQ), .STABLE_MS(1)) db_inst (
        .clk(clk), .rst(rst), .sw_in(sw_in), .edge_pulse(edge_pulse)
    );

    switch_string_sender sender_inst (
        .clk(clk), .rst(rst), .sw_edge_pulse(edge_pulse),
        .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy)
    );

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) tx_inst (
        .clk(clk), .rst(rst), .tx_start(tx_start), .tx_data(tx_data),
        .tx_line(tx_line), .tx_busy(tx_busy)
    );

    always #5 clk = ~clk;

    // ---- Fake "Arduino-side" UART receiver: bit-bangs decode of tx_line ----
    reg [7:0] received_chars [0:15];
    integer   received_count;

    task receive_byte_task;
        integer i;
        reg [7:0] value;
        begin
            @(negedge tx_line);           // start bit begins
            #(BIT_PERIOD * 1.5);          // land in the middle of D0
            value = 0;
            for (i = 0; i < 8; i = i + 1) begin
                value[i] = tx_line;
                #(BIT_PERIOD);
            end
            received_chars[received_count] = value;
            received_count = received_count + 1;
        end
    endtask

    integer errors = 0;
    integer tests  = 0;

    initial begin
        clk = 0;
        rst = 1;
        sw_in = 1'b0;
        received_count = 0;
        #50;
        rst = 0;
        #50;

        // Toggle the switch ON (rising edge)
        sw_in = 1'b1;

        // Receive 6 bytes: STX marker + AYUSH
        repeat (6) receive_byte_task;

        tests = tests + 1;
        if (received_count != 6) begin
            $display("FAIL: received %0d bytes, expected 6 (STX + AYUSH)", received_count);
            errors = errors + 1;
        end else if (received_chars[0] != 8'h02 || received_chars[1] != "A" || received_chars[2] != "Y" ||
                     received_chars[3] != "U" || received_chars[4] != "S" || received_chars[5] != "H") begin
            $display("FAIL: got %h %s%s%s%s%s, expected 02 AYUSH",
                      received_chars[0], received_chars[1], received_chars[2],
                      received_chars[3], received_chars[4], received_chars[5]);
            errors = errors + 1;
        end else begin
            $display("PASS: received STX+AYUSH correctly (%h %s%s%s%s%s)",
                      received_chars[0], received_chars[1], received_chars[2],
                      received_chars[3], received_chars[4], received_chars[5]);
        end

        // Toggle switch off then on again - should send STX+AYUSH a second time
        sw_in = 1'b0;
        #2_500_000;   // well over 2x the debounce stabilization time (1ms each way)
        sw_in = 1'b1;
        received_count = 0;
        repeat (6) receive_byte_task;

        tests = tests + 1;
        if (received_count != 6 || received_chars[0] != 8'h02 || received_chars[1] != "A" || received_chars[5] != "H") begin
            $display("FAIL: second trigger did not resend STX+AYUSH correctly");
            errors = errors + 1;
        end else begin
            $display("PASS: second switch toggle correctly resent STX+AYUSH");
        end

        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("%0d OF %0d TESTS FAILED", errors, tests);

        $finish;
    end

endmodule
