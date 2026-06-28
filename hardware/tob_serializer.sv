`timescale 1ns/1ps
// Top-of-book serializer: watches the LOB array's best level and, whenever it changes,
// streams a fixed 14-byte update frame out through a uart_tx instance (driven via the
// i_tx_busy / o_tx_start / o_tx_byte / i_tx_done handshake).
//
// Frame layout (matches the Mac ingress driver):
//   [0]     0xAA            sync byte (lets the host re-align on the byte stream)
//   [1:8]   price  (8 B BE, MSB first)
//   [9:12]  vol    (4 B BE)
//   [13]    checksum = XOR of bytes [1:12]
//
// A frame is emitted only while tob is valid and its (price, vol) differs from the last
// transmitted pair -- i.e. on inserts/updates/deletes that move the best level. A book
// that empties out (tob_valid -> 0) simply stops producing frames.
module tob_serializer #(
    parameter int   PRICE_W = 64,
    parameter int   VOL_W   = 32,
    parameter [7:0] SYNC    = 8'hAA
) (
    input  logic               clk,
    input  logic               rst_n,

    // Top-of-book from lob_array.
    input  logic               tob_valid,
    input  logic [PRICE_W-1:0] tob_price,
    input  logic [VOL_W-1:0]   tob_vol,

    // uart_tx handshake.
    input  logic               i_tx_busy,
    input  logic               i_tx_done,
    output logic               o_tx_start,
    output logic [7:0]         o_tx_byte
);

    localparam int FRAME_LEN = 1 + (PRICE_W/8) + (VOL_W/8) + 1;  // 14 for 64/32

    typedef enum logic [1:0] { S_IDLE, S_SEND, S_WAIT } state_t;
    state_t state;

    logic [7:0] frame [0:FRAME_LEN-1];
    logic [4:0] idx;

    // Last transmitted best level (for change detection).
    logic               last_valid;
    logic [PRICE_W-1:0] last_price;
    logic [VOL_W-1:0]   last_vol;

    wire changed = tob_valid &&
                   (!last_valid || tob_price != last_price || tob_vol != last_vol);

    // Combinational XOR checksum over the price+vol bytes (blocking accumulation).
    function automatic logic [7:0] xor_bytes(input logic [PRICE_W-1:0] p,
                                             input logic [VOL_W-1:0]   v);
        logic [7:0] x;
        x = '0;
        for (int b = 0; b < PRICE_W/8; b++) x ^= p[PRICE_W-1 - 8*b -: 8];
        for (int b = 0; b < VOL_W/8;   b++) x ^= v[VOL_W-1   - 8*b -: 8];
        return x;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            idx        <= '0;
            o_tx_start <= 1'b0;
            o_tx_byte  <= '0;
            last_valid <= 1'b0;
            last_price <= '0;
            last_vol   <= '0;
        end else begin
            o_tx_start <= 1'b0;  // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    if (changed && !i_tx_busy) begin
                        // Snapshot the best level into a 14-byte frame.
                        frame[0] <= SYNC;
                        for (int b = 0; b < PRICE_W/8; b++)
                            frame[1 + b] <= tob_price[PRICE_W-1 - 8*b -: 8];
                        for (int b = 0; b < VOL_W/8; b++)
                            frame[1 + PRICE_W/8 + b] <= tob_vol[VOL_W-1 - 8*b -: 8];
                        frame[FRAME_LEN-1] <= xor_bytes(tob_price, tob_vol);

                        last_valid <= 1'b1;
                        last_price <= tob_price;
                        last_vol   <= tob_vol;
                        idx        <= '0;
                        state      <= S_SEND;
                    end else if (!tob_valid) begin
                        last_valid <= 1'b0;
                    end
                end

                S_SEND: begin
                    if (!i_tx_busy) begin
                        o_tx_start <= 1'b1;
                        o_tx_byte  <= frame[idx];
                        state      <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (i_tx_done) begin
                        if (idx == FRAME_LEN-1) begin
                            state <= S_IDLE;
                        end else begin
                            idx   <= idx + 1'b1;
                            state <= S_SEND;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
