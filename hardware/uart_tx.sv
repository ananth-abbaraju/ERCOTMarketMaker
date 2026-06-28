`timescale 1ns/1ps
// Standard 8N1 UART transmitter (8 data bits, no parity, 1 stop bit, LSB first).
//
// Assert i_start for one cycle with the byte on i_byte while o_busy is low; the byte is
// latched and shifted out: start bit (low), 8 data bits LSB-first, stop bit (high). The
// line idles high. o_busy is held for the whole frame; o_done pulses for one cycle as the
// stop bit completes, which the caller uses to hand over the next byte.
//
// CLKS_PER_BIT = clk_freq / baud (868 at 100 MHz / 115200). Testbenches override it small.
module uart_tx #(
    parameter int CLKS_PER_BIT = 868
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       i_start,     // pulse to begin sending i_byte (ignored while busy)
    input  logic [7:0] i_byte,

    output logic       o_serial,    // serial output (idles high)
    output logic       o_busy,      // high for the duration of a frame
    output logic       o_done       // 1-cycle pulse when the frame finishes
);

    localparam int CW = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    typedef enum logic [2:0] {
        S_IDLE, S_START, S_DATA, S_STOP
    } state_t;
    state_t state;

    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shifter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            clk_cnt  <= '0;
            bit_idx  <= '0;
            shifter  <= '0;
            o_serial <= 1'b1;   // idle high
            o_busy   <= 1'b0;
            o_done   <= 1'b0;
        end else begin
            o_done <= 1'b0;     // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    o_serial <= 1'b1;
                    o_busy   <= 1'b0;
                    clk_cnt  <= '0;
                    bit_idx  <= '0;
                    if (i_start) begin
                        shifter  <= i_byte;
                        o_busy   <= 1'b1;
                        o_serial <= 1'b0;   // start bit
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt  <= '0;
                        o_serial <= shifter[0];  // first data bit (LSB)
                        state    <= S_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= '0;
                        if (bit_idx == 3'd7) begin
                            bit_idx  <= '0;
                            o_serial <= 1'b1;    // stop bit
                            state    <= S_STOP;
                        end else begin
                            bit_idx  <= bit_idx + 1'b1;
                            o_serial <= shifter[bit_idx + 1'b1];
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= '0;
                        o_busy  <= 1'b0;
                        o_done  <= 1'b1;
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
