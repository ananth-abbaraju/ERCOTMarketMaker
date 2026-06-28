`timescale 1ns/1ps
// Stage 2 of the two-stage MDP 3.0 / SBE decode. Chains onto mdp3_parser: it consumes
// the same byte stream plus the parser's header outputs (out_valid, msg_type,
// payload_len) and walks the SBE payload to extract the order's (price, volume).
//
// Why this module also GATES the parser:
//   mdp3_parser blindly frames every HEADER_LEN bytes as a new header -- it has no notion
//   of a payload. Left unchecked it would swallow the 12 payload bytes as a phantom header
//   and misframe everything after the first frame. So this decoder owns the frame phase:
//   in HEADER phase it forwards byte strobes to the parser (o_parser_valid); once the
//   parser reports a header, it switches to PAYLOAD phase, holds the parser idle, and
//   counts payload_len bytes itself. UART bytes arrive as single-cycle pulses spaced a
//   whole frame apart, so the parser's (registered) out_valid lands in the gap before the
//   first payload byte -- no simultaneity hazard.
//
// Payload layout (big-endian), as produced by the Mac feeder:
//   [0:7]   price  (int64 SBE mantissa, e.g. PRICE9)
//   [8:11]  volume (int32)
// Extraction is gated on msg_type == MSG_INCREMENTAL so non-order messages are consumed
// (to stay framed) but never emitted.
module mdp3_payload_decoder #(
    parameter int    PRICE_W        = 64,
    parameter int    VOL_W          = 32,
    parameter [15:0] MSG_INCREMENTAL = 16'd46  // CME MDIncrementalRefreshBook template id
) (
    input  logic        clk,
    input  logic        rst_n,

    // Raw byte stream (shared with mdp3_parser's in_byte).
    input  logic        in_valid,
    input  logic [7:0]  in_byte,

    // Header results from mdp3_parser.
    input  logic        hdr_valid,    // parser out_valid (1-cycle pulse)
    input  logic [15:0] msg_type,
    input  logic [15:0] payload_len,

    // Gate for the parser: feed it only the header bytes of each frame.
    output logic        o_parser_valid,

    // Decoded order, one pulse per incremental-refresh frame.
    output logic               o_valid,
    output logic [PRICE_W-1:0] o_price,
    output logic [VOL_W-1:0]   o_vol
);

    typedef enum logic [0:0] { S_HEADER, S_PAYLOAD } phase_t;
    phase_t phase;

    logic [15:0] rem;          // payload bytes still to consume
    logic [15:0] pidx;         // index of the current payload byte
    logic        msg_is_incr;  // captured at header time

    logic [PRICE_W-1:0] price_acc;
    logic [VOL_W-1:0]   vol_acc;

    // In HEADER phase the parser sees every byte; in PAYLOAD phase it is held idle.
    assign o_parser_valid = (phase == S_HEADER) && in_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase       <= S_HEADER;
            rem         <= '0;
            pidx        <= '0;
            msg_is_incr <= 1'b0;
            price_acc   <= '0;
            vol_acc     <= '0;
            o_valid     <= 1'b0;
            o_price     <= '0;
            o_vol       <= '0;
        end else begin
            o_valid <= 1'b0;  // default: single-cycle pulse

            case (phase)
                S_HEADER: begin
                    // Parser just finished a header: arm the payload walk.
                    if (hdr_valid && payload_len != 16'd0) begin
                        msg_is_incr <= (msg_type == MSG_INCREMENTAL);
                        rem         <= payload_len;
                        pidx        <= '0;
                        price_acc   <= '0;
                        vol_acc     <= '0;
                        phase       <= S_PAYLOAD;
                    end
                end

                S_PAYLOAD: begin
                    if (in_valid) begin
                        // Big-endian shift-in: first byte is the most significant.
                        if (pidx < 16'd8)
                            price_acc <= {price_acc[PRICE_W-9:0], in_byte};
                        else if (pidx < 16'd12)
                            vol_acc   <= {vol_acc[VOL_W-9:0], in_byte};
                        // bytes >= 12 (if any) are consumed but ignored

                        pidx <= pidx + 16'd1;

                        if (rem == 16'd1) begin
                            // Last payload byte just consumed.
                            phase <= S_HEADER;
                            if (msg_is_incr) begin
                                o_valid <= 1'b1;
                                o_price <= (pidx < 16'd8)
                                           ? {price_acc[PRICE_W-9:0], in_byte} : price_acc;
                                o_vol   <= (pidx >= 16'd8 && pidx < 16'd12)
                                           ? {vol_acc[VOL_W-9:0], in_byte} : vol_acc;
                            end
                        end else begin
                            rem <= rem - 16'd1;
                        end
                    end
                end

                default: phase <= S_HEADER;
            endcase
        end
    end

endmodule
