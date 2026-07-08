// debounce.v
// Debounces a noisy mechanical switch/button input and produces a
// single-cycle pulse on its rising edge (press/toggle-on only).

module debounce #(
    parameter integer CLK_FREQ    = 100_000_000,
    parameter integer STABLE_MS   = 10   // how long the signal must hold steady
)(
    input  wire clk,
    input  wire rst,
    input  wire sw_in,
    output reg  edge_pulse    // one-cycle pulse when a stable LOW->HIGH transition occurs
);

    localparam integer STABLE_CYCLES = (CLK_FREQ / 1000) * STABLE_MS;

    reg [31:0] counter;
    reg        sw_sync_0, sw_sync_1;   // 2-flop synchronizer (sw_in is asynchronous)
    reg        stable_state;
    reg        prev_stable_state;

    // Synchronize the asynchronous switch input into our clock domain
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sw_sync_0 <= 1'b0;
            sw_sync_1 <= 1'b0;
        end else begin
            sw_sync_0 <= sw_in;
            sw_sync_1 <= sw_sync_0;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            counter           <= 32'd0;
            stable_state      <= 1'b0;
            prev_stable_state <= 1'b0;
            edge_pulse        <= 1'b0;
        end else begin
            edge_pulse <= 1'b0;

            if (sw_sync_1 == stable_state) begin
                counter <= 32'd0;
            end else begin
                if (counter == STABLE_CYCLES - 1) begin
                    stable_state <= sw_sync_1;
                    counter      <= 32'd0;
                end else begin
                    counter <= counter + 32'd1;
                end
            end

            prev_stable_state <= stable_state;
            if (stable_state == 1'b1 && prev_stable_state == 1'b0)
                edge_pulse <= 1'b1;
        end
    end

endmodule
