`timescale 1ns/1ps
// Lightweight synthesizable header parser for CME MDP 3.0 (header-only).
// Streams bytes in (clk, rst_n, in_valid, in_byte) and pulses out_valid for one
// cycle per frame with the parsed header fields registered on the outputs.
//
// Header layout (big-endian, 20 bytes total):
//   [0:1]   msg_type      (16-bit)
//   [2:5]   seq_num       (32-bit)
//   [6:9]   instrument_id (32-bit)
//   [10:17] timestamp     (64-bit)
//   [18:19] payload_len   (16-bit)
//
// Design: a single byte counter drives everything -- no per-field FSM states are
// needed, since the field boundaries are fixed offsets. The parser is fully
// streaming and accepts back-to-back frames with zero idle gap: the counter
// resets on the final byte of a frame so the very next valid byte starts the
// next frame's msg_type.
module mdp3_parser #(
    parameter int HEADER_LEN = 20
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_byte,

    output logic        out_valid,
    output logic [15:0] msg_type,
    output logic [31:0] seq_num,
    output logic [31:0] instrument_id,
    output logic [63:0] timestamp,
    output logic [15:0] payload_len
);

    // Field offsets are wired to the 20-byte layout above.
    initial begin
        if (HEADER_LEN != 20)
            $error("mdp3_parser: field mapping assumes HEADER_LEN==20 (got %0d)", HEADER_LEN);
    end

    // byte_cnt indexes 0..HEADER_LEN-1; needs $clog2(HEADER_LEN) bits.
    localparam int CNT_W = $clog2(HEADER_LEN);
    logic [CNT_W-1:0] byte_cnt;

    // Header bytes are buffered as they stream in. The final byte (index 19) is
    // consumed combinationally from in_byte on the completing cycle, so only
    // bytes 0..18 ever need to be read back out of the buffer.
    logic [7:0] buf_mem [0:HEADER_LEN-2];

    // Final header byte is arriving this cycle -> frame completes.
    wire last_byte = in_valid && (byte_cnt == HEADER_LEN-1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt      <= '0;
            out_valid     <= 1'b0;
            msg_type      <= '0;
            seq_num       <= '0;
            instrument_id <= '0;
            timestamp     <= '0;
            payload_len   <= '0;
        end else begin
            out_valid <= 1'b0;  // default: single-cycle pulse

            if (in_valid) begin
                if (last_byte) begin
                    // Latch all fields (big-endian). buf_mem holds bytes 0..18;
                    // byte 19 (payload_len LSB) is the in_byte arriving now.
                    out_valid     <= 1'b1;
                    msg_type      <= {buf_mem[0],  buf_mem[1]};
                    seq_num       <= {buf_mem[2],  buf_mem[3],  buf_mem[4],  buf_mem[5]};
                    instrument_id <= {buf_mem[6],  buf_mem[7],  buf_mem[8],  buf_mem[9]};
                    timestamp     <= {buf_mem[10], buf_mem[11], buf_mem[12], buf_mem[13],
                                      buf_mem[14], buf_mem[15], buf_mem[16], buf_mem[17]};
                    payload_len   <= {buf_mem[18], in_byte};
                    byte_cnt      <= '0;  // re-arm immediately for the next frame
                end else begin
                    buf_mem[byte_cnt] <= in_byte;
                    byte_cnt          <= byte_cnt + 1'b1;
                end
            end
        end
    end

endmodule
