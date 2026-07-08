// seven_seg_driver.v
// Drives Basys3's 4-digit multiplexed common-anode 7-segment display.
// Shows a 16-bit value as 4 hex digits. Refreshes each digit in turn
// fast enough (~1kHz per digit) that persistence of vision makes all 4
// appear lit simultaneously.

module seven_seg_driver #(
    parameter integer CLK_FREQ = 100_000_000,
    parameter integer REFRESH_HZ = 1000  // per-digit refresh rate
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] value,     // 4 hex digits to display
    output reg  [6:0]  seg,       // active-low segments a-g
    output reg         dp,        // active-low decimal point (always off here)
    output reg  [3:0]  an         // active-low digit select
);

    localparam integer DIVIDER = CLK_FREQ / (REFRESH_HZ * 4);

    reg [31:0] div_counter;
    reg [1:0]  digit_sel;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_counter <= 32'd0;
            digit_sel   <= 2'd0;
        end else if (div_counter == DIVIDER - 1) begin
            div_counter <= 32'd0;
            digit_sel   <= digit_sel + 2'd1;
        end else begin
            div_counter <= div_counter + 32'd1;
        end
    end

    reg [3:0] current_nibble;
    always @(*) begin
        case (digit_sel)
            2'd0: current_nibble = value[3:0];
            2'd1: current_nibble = value[7:4];
            2'd2: current_nibble = value[11:8];
            2'd3: current_nibble = value[15:12];
            default: current_nibble = 4'd0;
        endcase
    end

    always @(*) begin
        an = 4'b1111;
        an[digit_sel] = 1'b0;   // active-low: pull the selected digit's anode low
    end

    always @(*) begin
        dp = 1'b1;  // decimal point off (active-low)
        case (current_nibble)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
    end

endmodule
