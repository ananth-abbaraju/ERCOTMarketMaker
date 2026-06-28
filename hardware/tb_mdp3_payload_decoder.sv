`timescale 1ns/1ps
// Self-checking testbench for the chained mdp3_parser -> mdp3_payload_decoder.
// Bytes are injected as single-cycle pulses with idle gaps (mimicking uart_rx output).
//
//   1. Incremental-refresh frame  -> decoder emits the extracted (price, vol).
//   2. Non-incremental frame       -> consumed but no emit; framing must recover.
//   3. Second incremental frame    -> decodes correctly (proves no misframe).
//
// A latching monitor records each decode pulse so the sequence can send a whole frame
// and then check the captured result (a frame takes ~160 cycles to stream in).
module tb_mdp3_payload_decoder();
    localparam [15:0] MSG_INCREMENTAL = 16'd46;
    localparam [15:0] MSG_OTHER       = 16'd12;

    logic clk, rst_n;
    logic       in_valid;
    logic [7:0] in_byte;

    // parser <-> decoder wires
    logic        parser_valid;     // decoder gates the parser with this
    logic        hdr_valid;
    logic [15:0] msg_type;
    logic [31:0] seq_num, instrument_id;
    logic [63:0] timestamp;
    logic [15:0] payload_len;

    logic        dec_valid;
    logic [63:0] dec_price;
    logic [31:0] dec_vol;

    int errors = 0;

    // Latching monitor: capture decode pulses + count them.
    logic [63:0] got_price;
    logic [31:0] got_vol;
    int          got_count;

    mdp3_parser parser (
        .clk(clk), .rst_n(rst_n),
        .in_valid(parser_valid), .in_byte(in_byte),
        .out_valid(hdr_valid), .msg_type(msg_type),
        .seq_num(seq_num), .instrument_id(instrument_id),
        .timestamp(timestamp), .payload_len(payload_len)
    );

    mdp3_payload_decoder #(
        .PRICE_W(64), .VOL_W(32), .MSG_INCREMENTAL(MSG_INCREMENTAL)
    ) decoder (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_byte(in_byte),
        .hdr_valid(hdr_valid), .msg_type(msg_type), .payload_len(payload_len),
        .o_parser_valid(parser_valid),
        .o_valid(dec_valid), .o_price(dec_price), .o_vol(dec_vol)
    );

    // 100MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            got_price <= '0; got_vol <= '0; got_count <= 0;
        end else if (dec_valid) begin
            got_price <= dec_price; got_vol <= dec_vol; got_count <= got_count + 1;
        end
    end

    // Inject one byte as a single-cycle pulse, then a short idle gap (UART-like spacing).
    task automatic push_byte(input logic [7:0] b);
        @(negedge clk);
        in_valid = 1'b1; in_byte = b;
        @(negedge clk);
        in_valid = 1'b0; in_byte = 8'h00;
        repeat (3) @(negedge clk);  // idle gap between bytes
    endtask

    // Push a full 32-byte frame: 20-byte header (payload_len=12) + 12-byte payload.
    task automatic send_frame(input logic [15:0] mtype,
                              input logic [63:0] price, input logic [31:0] vol);
        // Header (big-endian)
        push_byte(mtype[15:8]);  push_byte(mtype[7:0]);          // msg_type
        push_byte(8'h00); push_byte(8'h00); push_byte(8'h00); push_byte(8'h01); // seq_num
        push_byte(8'h00); push_byte(8'h00); push_byte(8'h00); push_byte(8'h2A); // instrument_id
        push_byte(8'h00); push_byte(8'h00); push_byte(8'h00); push_byte(8'h00);
        push_byte(8'h00); push_byte(8'h00); push_byte(8'h00); push_byte(8'h00); // timestamp
        push_byte(8'h00); push_byte(8'h0C);                      // payload_len = 12
        // Payload (big-endian): price[8] then vol[4]
        push_byte(price[63:56]); push_byte(price[55:48]); push_byte(price[47:40]); push_byte(price[39:32]);
        push_byte(price[31:24]); push_byte(price[23:16]); push_byte(price[15:8]);  push_byte(price[7:0]);
        push_byte(vol[31:24]);   push_byte(vol[23:16]);   push_byte(vol[15:8]);    push_byte(vol[7:0]);
        repeat (6) @(negedge clk);  // let the final decode pulse latch
    endtask

    task automatic check_decode(input string tag, input int e_count,
                                input logic [63:0] e_price, input logic [31:0] e_vol);
        if (got_count !== e_count) begin
            errors++; $error("[%s] decode count got %0d exp %0d", tag, got_count, e_count);
        end else begin
            if (got_price !== e_price) begin errors++; $error("[%s] price got %0d exp %0d", tag, got_price, e_price); end
            if (got_vol   !== e_vol)   begin errors++; $error("[%s] vol   got %0d exp %0d", tag, got_vol, e_vol);     end
            $display("[%s] decoded price=%0d vol=%0d (count=%0d)", tag, got_price, got_vol, got_count);
        end
    endtask

    initial begin
        rst_n = 0; in_valid = 0; in_byte = 0;
        #20;
        rst_n = 1;
        @(negedge clk);

        // 1. Incremental frame with a large 64-bit price.
        send_frame(MSG_INCREMENTAL, 64'h0000_00E8_D4A5_1000, 32'd250);
        check_decode("incr1", 1, 64'h0000_00E8_D4A5_1000, 32'd250);

        // 2. Non-incremental frame: consumed, no emit (count must NOT advance).
        send_frame(MSG_OTHER, 64'd777, 32'd9);
        check_decode("other", 1, 64'h0000_00E8_D4A5_1000, 32'd250);

        // 3. Another incremental frame must still decode (proves no misframe).
        send_frame(MSG_INCREMENTAL, 64'd1000000000, 32'd0);  // vol==0 (a delete)
        check_decode("incr2_delete", 2, 64'd1000000000, 32'd0);

        if (errors == 0)
            $display("RESULT: PASS (header+payload SBE decode, type gating, reframing)");
        else
            $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end

    // Safety timeout so the sim never hangs.
    initial begin
        #200000;
        $error("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
