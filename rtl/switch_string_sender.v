// switch_string_sender.v
// On a debounced switch rising edge, sends a fixed 5-character ASCII
// string ("AYUSH") over UART, one byte at a time, waiting for tx_busy
// to clear between each byte.

module switch_string_sender (
    input  wire clk,
    input  wire rst,
    input  wire sw_edge_pulse,   // one-cycle pulse from debounce.v

    output reg  [7:0] tx_data,
    output reg        tx_start,
    input  wire        tx_busy
);

    localparam [7:0] CHAR_STX = 8'h02;  // marker: "this is an unsolicited message, not an SPI response"
    localparam [7:0] CHAR_A = "A";
    localparam [7:0] CHAR_Y = "Y";
    localparam [7:0] CHAR_U = "U";
    localparam [7:0] CHAR_S = "S";
    localparam [7:0] CHAR_H = "H";

    reg [7:0] message [0:5];
    initial begin
        message[0] = CHAR_STX;
        message[1] = CHAR_A;
        message[2] = CHAR_Y;
        message[3] = CHAR_U;
        message[4] = CHAR_S;
        message[5] = CHAR_H;
    end

    localparam [1:0] IDLE       = 2'd0;
    localparam [1:0] WAIT_READY = 2'd1;
    localparam [1:0] SEND_CHAR  = 2'd2;

    reg [1:0] state;
    reg [2:0] char_index;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= IDLE;
            char_index <= 3'd0;
            tx_data    <= 8'd0;
            tx_start   <= 1'b0;
        end else begin
            tx_start <= 1'b0;  // default: one-cycle pulse

            case (state)
                IDLE: begin
                    if (sw_edge_pulse) begin
                        char_index <= 3'd0;
                        state      <= WAIT_READY;
                    end
                end

                WAIT_READY: begin
                    if (!tx_busy) begin
                        tx_data  <= message[char_index];
                        tx_start <= 1'b1;
                        state    <= SEND_CHAR;
                    end
                end

                SEND_CHAR: begin
                    // wait for busy to actually assert (confirms the byte
                    // was accepted) before moving on to the next character
                    if (tx_busy) begin
                        if (char_index == 3'd5) begin
                            state <= IDLE;
                        end else begin
                            char_index <= char_index + 3'd1;
                            state      <= WAIT_READY;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
