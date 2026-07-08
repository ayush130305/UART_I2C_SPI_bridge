`timescale 1ns/1ps

module tb_i2c_master;

    localparam CLK_FREQ = 100_000_000;
    localparam SCL_FREQ = 100_000;

    reg        clk;
    reg        rst;
    reg        start;
    reg  [6:0] dev_addr;
    reg  [4:0] num_write_bytes;
    reg  [4:0] num_read_bytes;
    wire       byte_req;
    reg  [7:0] wr_data;
    wire       read_byte_valid;
    wire [7:0] read_byte_data;
    wire       busy;
    wire       done;
    wire       ack_error;

    wire sda_oe, scl_oe, sda_in;
    wire sda_line, scl_line;
    reg  slave_sda_oe;

    assign sda_line = sda_oe ? 1'b0 : 1'bz;
    assign sda_line = slave_sda_oe ? 1'b0 : 1'bz;
    assign scl_line = scl_oe ? 1'b0 : 1'bz;
    assign (weak0, weak1) sda_line = 1'b1;
    assign (weak0, weak1) scl_line = 1'b1;
    assign sda_in = sda_line;

    integer errors = 0;
    integer tests  = 0;

    i2c_master #(.CLK_FREQ(CLK_FREQ), .SCL_FREQ(SCL_FREQ)) dut (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .dev_addr        (dev_addr),
        .num_write_bytes (num_write_bytes),
        .num_read_bytes  (num_read_bytes),
        .byte_req        (byte_req),
        .wr_data         (wr_data),
        .read_byte_valid (read_byte_valid),
        .read_byte_data  (read_byte_data),
        .busy            (busy),
        .done            (done),
        .ack_error       (ack_error),
        .sda_oe          (sda_oe),
        .sda_in          (sda_in),
        .scl_oe          (scl_oe)
    );

    always #5 clk = ~clk;

    // ---- write data source: presents next byte combinationally when
    //      byte_req pulses, per the handshake contract ----
    reg [7:0] data_to_send [0:15];
    integer   send_index;

    always @(*) wr_data = data_to_send[send_index];

    always @(posedge clk or posedge rst) begin
        if (rst) send_index <= 0;
        else if (byte_req) send_index <= send_index + 1;
    end

    // ---- captured read results ----
    reg [7:0] captured_reads [0:15];
    integer   captured_count;

    always @(posedge clk or posedge rst) begin
        if (rst) captured_count <= 0;
        else if (read_byte_valid) begin
            captured_reads[captured_count] <= read_byte_data;
            captured_count                 <= captured_count + 1;
        end
    end

    // ---- Bidirectional fake I2C slave ----
    // mode 0 = RECEIVE (sampling bits master is sending),
    // mode 1 = SEND (driving canned bytes back to master)
    // Switches to SEND right after ACKing an address byte whose R/W bit
    // (LSB of the address+RW byte) is 1. Doesn't bother checking the
    // master's ack/nack during SEND - since the test always requests an
    // exact known byte count, it just drives that many bytes and stops.
    reg [7:0] slave_shift;
    reg [3:0] bits_seen;
    reg       driving_ack;
    reg       mode;               // 0=RECEIVE, 1=SEND
    reg       is_first_byte;      // true for the address byte right after (repeated-)START
    reg       pending_send_switch;
    reg [7:0] send_shift;
    reg [3:0] send_bits_done;
    reg [7:0] read_data_to_send [0:15];
    integer   send_data_index;

    reg [7:0] i2c_received_bytes [0:15];
    integer   i2c_received_count;

    reg prev_scl, prev_sda;
    reg transaction_active;

    initial begin
        slave_sda_oe        = 1'b0;
        bits_seen           = 4'd0;
        driving_ack         = 1'b0;
        mode                = 1'b0;
        is_first_byte       = 1'b1;
        pending_send_switch = 1'b0;
        send_bits_done      = 4'd0;
        send_data_index     = 0;
        i2c_received_count  = 0;
        transaction_active  = 1'b0;
    end

    always @(posedge clk) begin
        prev_scl <= scl_line;
        prev_sda <= sda_line;

        // START or repeated-START: SDA falls while SCL high
        if (prev_scl===1'b1 && scl_line===1'b1 && prev_sda===1'b1 && sda_line===1'b0) begin
            transaction_active  <= 1'b1;
            bits_seen           <= 4'd0;
            mode                <= 1'b0;      // an address byte is always "received" first
            driving_ack         <= 1'b0;
            is_first_byte       <= 1'b1;
            pending_send_switch <= 1'b0;
        end
        // STOP: SDA rises while SCL high
        else if (prev_scl===1'b1 && scl_line===1'b1 && prev_sda===1'b0 && sda_line===1'b1) begin
            transaction_active <= 1'b0;
            slave_sda_oe       <= 1'b0;
        end
        // Rising edge while active
        else if (transaction_active && prev_scl===1'b0 && scl_line===1'b1) begin
            if (mode == 1'b0 && bits_seen < 4'd8) begin
                slave_shift <= {slave_shift[6:0], sda_line};
                bits_seen   <= bits_seen + 4'd1;
            end
            // mode==1 (SEND): nothing to do on rising edge, master is
            // sampling what we already set up on the previous falling edge
        end
        // Falling edge while active
        else if (transaction_active && prev_scl===1'b1 && scl_line===1'b0) begin
            if (mode == 1'b0) begin
                if (bits_seen == 4'd8 && !driving_ack) begin
                    // just finished receiving 8 bits - drive ACK now
                    slave_sda_oe                            <= 1'b1;
                    driving_ack                              <= 1'b1;
                    i2c_received_bytes[i2c_received_count]  <= slave_shift;
                    i2c_received_count                       <= i2c_received_count + 1;
                    if (is_first_byte && slave_shift[0] == 1'b1) begin
                        pending_send_switch <= 1'b1;
                    end
                    is_first_byte <= 1'b0;
                end else if (driving_ack) begin
                    // ack cell over - release, prepare next byte
                    slave_sda_oe <= 1'b0;
                    driving_ack  <= 1'b0;
                    bits_seen    <= 4'd0;
                    if (pending_send_switch) begin
                        mode                <= 1'b1;
                        pending_send_switch <= 1'b0;
                        // Drive the FIRST send bit on THIS same edge, not
                        // deferred to the next one - otherwise master's
                        // single-tick READ_SETUP samples before we've
                        // driven anything, corrupting every bit by one
                        // position (found via cycle-by-cycle trace).
                        slave_sda_oe    <= read_data_to_send[send_data_index][7] ? 1'b0 : 1'b1;
                        send_shift      <= {read_data_to_send[send_data_index][6:0], 1'b0};
                        send_bits_done  <= 4'd1;
                        send_data_index <= send_data_index + 1;
                    end
                end
            end else begin
                // mode==1 (SEND)
                if (send_bits_done < 4'd8) begin
                    slave_sda_oe   <= send_shift[7] ? 1'b0 : 1'b1;  // MSB first
                    send_shift     <= {send_shift[6:0], 1'b0};
                    send_bits_done <= send_bits_done + 4'd1;
                end else begin
                    // 8 bits sent - release SDA for master's ack/nack, then
                    // (regardless of which) set up the next byte
                    slave_sda_oe    <= 1'b0;
                    send_bits_done  <= 4'd0;
                    send_shift      <= read_data_to_send[send_data_index];
                    send_data_index <= send_data_index + 1;
                end
            end
        end
    end

    task do_i2c_transaction(input [6:0] addr, input integer nwrite, input integer nread);
        begin
            @(negedge clk);   // sync to a known point, regardless of caller timing
            send_index          = 0;
            captured_count       = 0;
            i2c_received_count   = 0;
            send_data_index      = 0;
            // Explicitly reset ALL slave bookkeeping before every
            // transaction - relying solely on START-detection to reset
            // this isn't enough: if the bus is already in a bad state
            // left over from a previous test (e.g. mode stuck at SEND),
            // the exact-match (===) START detection can fail to fire at
            // all, since it needs a clean prev_sda===1 reading first.
            slave_sda_oe         = 1'b0;
            bits_seen            = 4'd0;
            driving_ack          = 1'b0;
            mode                 = 1'b0;
            is_first_byte        = 1'b1;
            pending_send_switch  = 1'b0;
            send_bits_done       = 4'd0;
            transaction_active   = 1'b0;
            dev_addr        <= addr;
            num_write_bytes <= nwrite[4:0];
            num_read_bytes  <= nread[4:0];
            start           <= 1'b1;
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
        clk             = 0;
        rst             = 1;
        start           = 1'b0;
        dev_addr        = 7'd0;
        num_write_bytes = 5'd0;
        num_read_bytes  = 5'd0;
        #50;
        rst = 0;
        #50;

        // ================= TEST 1: write-only regression =================
        // (same scenario as the original v1 test - confirms backward compat)
        data_to_send[0] = 8'hAA;
        data_to_send[1] = 8'hBB;
        data_to_send[2] = 8'hCC;
        do_i2c_transaction(7'h50, 3, 0);
        wait_for_done(60000);

        tests = tests + 1;
        if (ack_error) begin
            $display("FAIL(1): ack_error asserted unexpectedly");
            errors = errors + 1;
        end else if (i2c_received_count != 4) begin
            $display("FAIL(1): slave received %0d bytes, expected 4 (address + 3 data)", i2c_received_count);
            errors = errors + 1;
        end else if (i2c_received_bytes[0] !== {7'h50,1'b0} || i2c_received_bytes[1] !== 8'hAA ||
                     i2c_received_bytes[2] !== 8'hBB || i2c_received_bytes[3] !== 8'hCC) begin
            $display("FAIL(1): got %h %h %h %h, expected a0 aa bb cc",
                      i2c_received_bytes[0], i2c_received_bytes[1], i2c_received_bytes[2], i2c_received_bytes[3]);
            errors = errors + 1;
        end else begin
            $display("PASS(1): write-only regression OK (%h %h %h %h)",
                      i2c_received_bytes[0], i2c_received_bytes[1], i2c_received_bytes[2], i2c_received_bytes[3]);
        end

        #2000;

        // ================= TEST 2: read-only =================
        read_data_to_send[0] = 8'h11;
        read_data_to_send[1] = 8'h22;
        read_data_to_send[2] = 8'h33;
        do_i2c_transaction(7'h68, 0, 3);
        wait_for_done(80000);

        tests = tests + 1;
        if (ack_error) begin
            $display("FAIL(2): ack_error asserted unexpectedly");
            errors = errors + 1;
        end else if (captured_count != 3) begin
            $display("FAIL(2): master captured %0d bytes, expected 3", captured_count);
            errors = errors + 1;
        end else if (captured_reads[0] !== 8'h11 || captured_reads[1] !== 8'h22 || captured_reads[2] !== 8'h33) begin
            $display("FAIL(2): got %h %h %h, expected 11 22 33",
                      captured_reads[0], captured_reads[1], captured_reads[2]);
            errors = errors + 1;
        end else if (i2c_received_bytes[0] !== {7'h68,1'b1}) begin
            $display("FAIL(2): address byte slave saw = %h, expected %h (addr+R)", i2c_received_bytes[0], {7'h68,1'b1});
            errors = errors + 1;
        end else begin
            $display("PASS(2): read-only OK, captured (%h %h %h)",
                      captured_reads[0], captured_reads[1], captured_reads[2]);
        end

        #2000;

        // ================= TEST 3: combined write-then-read (register-read pattern) =================
        // e.g. "write register address 0x75 (WHO_AM_I), then read 1 byte back"
        data_to_send[0]      = 8'h75;   // register address to write
        read_data_to_send[0] = 8'h68;   // canned "WHO_AM_I" response
        do_i2c_transaction(7'h68, 1, 1);
        wait_for_done(90000);

        tests = tests + 1;
        if (ack_error) begin
            $display("FAIL(3): ack_error asserted unexpectedly");
            errors = errors + 1;
        end else if (captured_count != 1) begin
            $display("FAIL(3): master captured %0d bytes, expected 1", captured_count);
            errors = errors + 1;
        end else if (captured_reads[0] !== 8'h68) begin
            $display("FAIL(3): captured %h, expected 68 (WHO_AM_I style response)", captured_reads[0]);
            errors = errors + 1;
        end else if (i2c_received_count != 3) begin
            // expected: addr+W, register-addr data byte, addr+R (repeated start)
            $display("FAIL(3): slave saw %0d received bytes, expected 3 (addr+W, reg_addr, addr+R)", i2c_received_count);
            errors = errors + 1;
        end else if (i2c_received_bytes[0] !== {7'h68,1'b0} || i2c_received_bytes[1] !== 8'h75 ||
                     i2c_received_bytes[2] !== {7'h68,1'b1}) begin
            $display("FAIL(3): slave saw %h %h %h, expected d0 75 d1",
                      i2c_received_bytes[0], i2c_received_bytes[1], i2c_received_bytes[2]);
            errors = errors + 1;
        end else begin
            $display("PASS(3): combined write-then-read (repeated-START) OK - wrote reg 0x75, read back %h",
                      captured_reads[0]);
        end

        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("%0d OF %0d TESTS FAILED", errors, tests);

        $finish;
    end

endmodule
