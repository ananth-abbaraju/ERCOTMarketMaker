`timescale 1ns/1ps
// Standard 8N1 UART receiver (8 data bits, no parity, 1 stop bit, LSB first).
//
// The line idles high. A falling edge starts a frame: we wait half a bit period to
// land in the middle of the start bit, confirm it is still low, then sample each of
// the 8 data bits one bit-period apart (again at mid-bit). After the stop bit the
// assembled byte is presented on o_byte with a single-cycle o_valid pulse.
//
// CLKS_PER_BIT = clk_freq / baud. At 100 MHz / 115200 baud that is 868. Testbenches
// override it with a small value so a byte takes a handful of cycles instead of
// thousands, keeping simulation fast.
module uart_rx #(
    parameter int CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       i_rx,        // serial input (idles high)

    output logic       o_valid,     // 1-cycle pulse when o_byte is fresh
    output logic [7:0] o_byte
);

    // Need to count up to CLKS_PER_BIT-1, and index 8 data bits.
    localparam int CW = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    typedef enum logic [2:0] {
        S_IDLE, S_START, S_DATA, S_STOP
    } state_t;
    state_t state;

    // Two-flop synchronizer on the async serial line (metastability guard).
    logic rx_meta, rx_sync;

    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shifter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            state   <= S_IDLE;
            clk_cnt <= '0;
            bit_idx <= '0;
            shifter <= '0;
            o_valid <= 1'b0;
            o_byte  <= '0;
        end else begin
            // Synchronize the incoming line first.
            rx_meta <= i_rx;
            rx_sync <= rx_meta;

            o_valid <= 1'b0;  // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (rx_sync == 1'b0)  // start bit detected
                        state <= S_START;
                end

                // Wait to the middle of the start bit, then re-check it is still low.
                S_START: begin
                    if (clk_cnt == (CLKS_PER_BIT - 1) / 2) begin
                        if (rx_sync == 1'b0) begin
                            clk_cnt <= '0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;  // false start (glitch)
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Sample 8 data bits, one bit-period apart, at mid-bit.
                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt          <= '0;
                        shifter[bit_idx] <= rx_sync;  // LSB first
                        if (bit_idx == 3'd7) begin
                            bit_idx <= '0;
                            state   <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // Ride out the stop bit, then emit the byte.
                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= '0;
                        o_byte  <= shifter;
                        o_valid <= 1'b1;
                        state   <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
