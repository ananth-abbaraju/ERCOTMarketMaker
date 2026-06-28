`timescale 1ns/1ps
// Self-checking testbench for lob_pe (single bidirectional LOB Processing Element).
//
//   BID PE (IS_BID=1, higher better): fill -> worse -> match -> better -> idle
//                                     -> delete (pull from right + collapse token)
//   ASK PE (IS_BID=0, lower  better): fill -> worse -> better   (direction flips)
//
// Timing: outputs are registered, so inputs are driven with blocking assignment on
// negedge (stable across the DUT posedge); after one posedge (+#1 to let NBA settle)
// the registered state and rightward output reflect that operation.
module tb_lob_pe();
    localparam int PRICE_W = 32;
    localparam int VOL_W   = 32;

    logic clk, rst_n;

    // --- BID PE nets ---
    logic               b_il_valid, b_il_col;
    logic [PRICE_W-1:0] b_il_price;
    logic [VOL_W-1:0]   b_il_vol;
    logic               b_ir_occ;
    logic [PRICE_W-1:0] b_ir_price;
    logic [VOL_W-1:0]   b_ir_vol;
    logic               b_or_valid, b_or_col;
    logic [PRICE_W-1:0] b_or_price;
    logic [VOL_W-1:0]   b_or_vol;
    logic               b_occ;
    logic [PRICE_W-1:0] b_price_s;
    logic [VOL_W-1:0]   b_vol_s;

    // --- ASK PE nets ---
    logic               a_il_valid, a_il_col;
    logic [PRICE_W-1:0] a_il_price;
    logic [VOL_W-1:0]   a_il_vol;
    logic               a_ir_occ;
    logic [PRICE_W-1:0] a_ir_price;
    logic [VOL_W-1:0]   a_ir_vol;
    logic               a_or_valid, a_or_col;
    logic [PRICE_W-1:0] a_or_price;
    logic [VOL_W-1:0]   a_or_vol;
    logic               a_occ;
    logic [PRICE_W-1:0] a_price_s;
    logic [VOL_W-1:0]   a_vol_s;

    int errors = 0;

    lob_pe #(.PRICE_W(PRICE_W), .VOL_W(VOL_W), .IS_BID(1'b1)) bid_pe (
        .clk(clk), .rst_n(rst_n),
        .in_left_valid(b_il_valid), .in_left_is_collapse(b_il_col),
        .in_left_price(b_il_price), .in_left_vol(b_il_vol),
        .out_right_valid(b_or_valid), .out_right_is_collapse(b_or_col),
        .out_right_price(b_or_price), .out_right_vol(b_or_vol),
        .in_right_occupied(b_ir_occ), .in_right_price(b_ir_price), .in_right_vol(b_ir_vol),
        .out_left_occupied(), .out_left_price(), .out_left_vol(),
        .occupied(b_occ), .price(b_price_s), .vol(b_vol_s)
    );

    lob_pe #(.PRICE_W(PRICE_W), .VOL_W(VOL_W), .IS_BID(1'b0)) ask_pe (
        .clk(clk), .rst_n(rst_n),
        .in_left_valid(a_il_valid), .in_left_is_collapse(a_il_col),
        .in_left_price(a_il_price), .in_left_vol(a_il_vol),
        .out_right_valid(a_or_valid), .out_right_is_collapse(a_or_col),
        .out_right_price(a_or_price), .out_right_vol(a_or_vol),
        .in_right_occupied(a_ir_occ), .in_right_price(a_ir_price), .in_right_vol(a_ir_vol),
        .out_left_occupied(), .out_left_price(), .out_left_vol(),
        .occupied(a_occ), .price(a_price_s), .vol(a_vol_s)
    );

    // 100MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Drive a PE's inputs on negedge (blocking; stable across the DUT posedge).
    // in_right defaults to empty unless an explicit value is supplied (collapse test).
    task automatic bid_apply(input logic v, input logic col,
                             input logic [PRICE_W-1:0] p, input logic [VOL_W-1:0] q,
                             input logic ir_occ, input logic [PRICE_W-1:0] ir_p, input logic [VOL_W-1:0] ir_q);
        @(negedge clk);
        b_il_valid = v; b_il_col = col; b_il_price = p; b_il_vol = q;
        b_ir_occ = ir_occ; b_ir_price = ir_p; b_ir_vol = ir_q;
    endtask
    task automatic ask_apply(input logic v, input logic col,
                             input logic [PRICE_W-1:0] p, input logic [VOL_W-1:0] q,
                             input logic ir_occ, input logic [PRICE_W-1:0] ir_p, input logic [VOL_W-1:0] ir_q);
        @(negedge clk);
        a_il_valid = v; a_il_col = col; a_il_price = p; a_il_vol = q;
        a_ir_occ = ir_occ; a_ir_price = ir_p; a_ir_vol = ir_q;
    endtask

    // Check stored level + rightward output. out_price/out_vol only checked on a
    // normal (non-collapse) shove.
    task automatic expect_bid(
        input string tag,
        input logic e_occ, input logic [PRICE_W-1:0] e_price, input logic [VOL_W-1:0] e_vol,
        input logic e_ov, input logic e_oc, input logic [PRICE_W-1:0] e_op, input logic [VOL_W-1:0] e_oq
    );
        if (b_occ     !== e_occ)   begin errors++; $error("[%s] occupied  got %b exp %b", tag, b_occ, e_occ);     end
        if (b_price_s !== e_price) begin errors++; $error("[%s] price     got %0d exp %0d", tag, b_price_s, e_price); end
        if (b_vol_s   !== e_vol)   begin errors++; $error("[%s] vol       got %0d exp %0d", tag, b_vol_s, e_vol);   end
        if (b_or_valid!== e_ov)    begin errors++; $error("[%s] out_valid got %b exp %b", tag, b_or_valid, e_ov);  end
        if (b_or_col  !== e_oc)    begin errors++; $error("[%s] out_coll  got %b exp %b", tag, b_or_col, e_oc);    end
        if (e_ov && !e_oc) begin
            if (b_or_price !== e_op) begin errors++; $error("[%s] out_price got %0d exp %0d", tag, b_or_price, e_op); end
            if (b_or_vol   !== e_oq) begin errors++; $error("[%s] out_vol   got %0d exp %0d", tag, b_or_vol, e_oq);   end
        end
        $display("[%s] occ=%b price=%0d vol=%0d | out_v=%b col=%b p=%0d q=%0d",
                 tag, b_occ, b_price_s, b_vol_s, b_or_valid, b_or_col, b_or_price, b_or_vol);
    endtask

    task automatic expect_ask(
        input string tag,
        input logic e_occ, input logic [PRICE_W-1:0] e_price, input logic [VOL_W-1:0] e_vol,
        input logic e_ov, input logic e_oc, input logic [PRICE_W-1:0] e_op, input logic [VOL_W-1:0] e_oq
    );
        if (a_occ     !== e_occ)   begin errors++; $error("[%s] occupied  got %b exp %b", tag, a_occ, e_occ);     end
        if (a_price_s !== e_price) begin errors++; $error("[%s] price     got %0d exp %0d", tag, a_price_s, e_price); end
        if (a_vol_s   !== e_vol)   begin errors++; $error("[%s] vol       got %0d exp %0d", tag, a_vol_s, e_vol);   end
        if (a_or_valid!== e_ov)    begin errors++; $error("[%s] out_valid got %b exp %b", tag, a_or_valid, e_ov);  end
        if (a_or_col  !== e_oc)    begin errors++; $error("[%s] out_coll  got %b exp %b", tag, a_or_col, e_oc);    end
        if (e_ov && !e_oc) begin
            if (a_or_price !== e_op) begin errors++; $error("[%s] out_price got %0d exp %0d", tag, a_or_price, e_op); end
            if (a_or_vol   !== e_oq) begin errors++; $error("[%s] out_vol   got %0d exp %0d", tag, a_or_vol, e_oq);   end
        end
        $display("[%s] occ=%b price=%0d vol=%0d | out_v=%b col=%b p=%0d q=%0d",
                 tag, a_occ, a_price_s, a_vol_s, a_or_valid, a_or_col, a_or_price, a_or_vol);
    endtask

    initial begin
        rst_n = 0;
        b_il_valid=0; b_il_col=0; b_il_price=0; b_il_vol=0; b_ir_occ=0; b_ir_price=0; b_ir_vol=0;
        a_il_valid=0; a_il_col=0; a_il_price=0; a_il_vol=0; a_ir_occ=0; a_ir_price=0; a_ir_vol=0;
        #20;
        rst_n = 1;

        // ---------------- BID PE: higher price is better ----------------
        bid_apply(1,0, 100, 5, 0,0,0);  @(posedge clk); #1;
        expect_bid("BID.fill",   1'b1, 100, 5, 1'b0, 1'b0, 0, 0);

        bid_apply(1,0, 90, 3, 0,0,0);   @(posedge clk); #1;
        expect_bid("BID.worse",  1'b1, 100, 5, 1'b1, 1'b0, 90, 3);

        bid_apply(1,0, 100, 8, 0,0,0);  @(posedge clk); #1;
        expect_bid("BID.match",  1'b1, 100, 8, 1'b0, 1'b0, 0, 0);

        bid_apply(1,0, 110, 2, 0,0,0);  @(posedge clk); #1;
        expect_bid("BID.better", 1'b1, 110, 2, 1'b1, 1'b0, 100, 8);

        bid_apply(0,0, 0, 0, 0,0,0);    @(posedge clk); #1;
        expect_bid("BID.idle",   1'b1, 110, 2, 1'b0, 1'b0, 0, 0);

        // DELETE: order (110, vol=0) matches stored 110 -> pull right neighbor (50/7)
        // into this PE and emit a collapse token rightward.
        bid_apply(1,0, 110, 0, 1, 50, 7);  @(posedge clk); #1;
        expect_bid("BID.delete", 1'b1, 50, 7, 1'b1, 1'b1, 0, 0);

        // ---------------- ASK PE: lower price is better ----------------
        ask_apply(1,0, 100, 5, 0,0,0);  @(posedge clk); #1;
        expect_ask("ASK.fill",   1'b1, 100, 5, 1'b0, 1'b0, 0, 0);

        ask_apply(1,0, 110, 3, 0,0,0);  @(posedge clk); #1;
        expect_ask("ASK.worse",  1'b1, 100, 5, 1'b1, 1'b0, 110, 3);

        ask_apply(1,0, 90, 4, 0,0,0);   @(posedge clk); #1;
        expect_ask("ASK.better", 1'b1, 90, 4, 1'b1, 1'b0, 100, 5);

        if (errors == 0)
            $display("RESULT: PASS (bid+ask PE: fill/worse/match/better/idle/delete correct)");
        else
            $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end

    // Safety timeout so the sim never hangs.
    initial begin
        #10000;
        $error("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
