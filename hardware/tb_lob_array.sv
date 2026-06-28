`timescale 1ns/1ps
// Self-checking testbench for lob_array (chained systolic LOB, DEPTH=16, bid book).
//
//   1. Insert 4 prices OUT OF ORDER  -> proves shove-down sorting across PEs.
//   2. Delete the level at PE[1]      -> proves delete pull-up gap-heal ripples.
//
// One operation in flight at a time: each op is followed by settle() to let the
// ripple finish before the next op or any check.
module tb_lob_array();
    localparam int DEPTH   = 16;
    localparam int PRICE_W = 32;
    localparam int VOL_W   = 32;

    logic clk, rst_n;
    logic               in_valid;
    logic [PRICE_W-1:0] in_price;
    logic [VOL_W-1:0]   in_vol;

    logic               tob_valid;
    logic [PRICE_W-1:0] tob_price;
    logic [VOL_W-1:0]   tob_vol;

    logic [DEPTH-1:0]         book_occupied;
    logic [DEPTH*PRICE_W-1:0] book_price;
    logic [DEPTH*VOL_W-1:0]   book_vol;

    int errors = 0;

    lob_array #(.DEPTH(DEPTH), .PRICE_W(PRICE_W), .VOL_W(VOL_W), .IS_BID(1'b1)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_price(in_price), .in_vol(in_vol),
        .tob_valid(tob_valid), .tob_price(tob_price), .tob_vol(tob_vol),
        .book_occupied(book_occupied), .book_price(book_price), .book_vol(book_vol)
    );

    // 100MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Inject one operation for a single clock (vol>0 = insert/update, vol==0 = delete).
    task automatic do_op(input logic [PRICE_W-1:0] p, input logic [VOL_W-1:0] q);
        @(negedge clk);
        in_valid = 1'b1; in_price = p; in_vol = q;
        @(negedge clk);
        in_valid = 1'b0; in_price = '0; in_vol = '0;
    endtask

    // Let an in-flight ripple fully settle (one op in flight at a time).
    task automatic settle();
        repeat (DEPTH + 4) @(posedge clk);
        #1;
    endtask

    // Check one book level (PE[idx]) against expectations.
    task automatic check_pe(input string tag, input int idx,
                            input logic e_occ,
                            input logic [PRICE_W-1:0] e_price,
                            input logic [VOL_W-1:0]   e_vol);
        logic               g_occ;
        logic [PRICE_W-1:0] g_price;
        logic [VOL_W-1:0]   g_vol;
        g_occ   = book_occupied[idx];
        g_price = book_price[idx*PRICE_W +: PRICE_W];
        g_vol   = book_vol[idx*VOL_W +: VOL_W];
        if (g_occ !== e_occ) begin
            errors++; $error("[%s] PE[%0d] occupied got %b exp %b", tag, idx, g_occ, e_occ);
        end else if (e_occ) begin
            if (g_price !== e_price) begin errors++; $error("[%s] PE[%0d] price got %0d exp %0d", tag, idx, g_price, e_price); end
            if (g_vol   !== e_vol)   begin errors++; $error("[%s] PE[%0d] vol   got %0d exp %0d", tag, idx, g_vol, e_vol);     end
        end
    endtask

    // Dump the occupied prefix of the book for visibility.
    task automatic dump(input string tag);
        $write("[%s] book:", tag);
        for (int k = 0; k < DEPTH; k++)
            if (book_occupied[k])
                $write(" PE[%0d]=%0d/%0d", k,
                       book_price[k*PRICE_W +: PRICE_W], book_vol[k*VOL_W +: VOL_W]);
        $write("\n");
    endtask

    task automatic check_tob(input string tag, input logic [PRICE_W-1:0] e_price,
                             input logic [VOL_W-1:0] e_vol);
        if (tob_valid !== 1'b1 || tob_price !== e_price || tob_vol !== e_vol) begin
            errors++;
            $error("[%s] top-of-book got v=%b %0d/%0d exp 1 %0d/%0d",
                   tag, tob_valid, tob_price, tob_vol, e_price, e_vol);
        end
    endtask

    initial begin
        rst_n = 0; in_valid = 0; in_price = 0; in_vol = 0;
        #20;
        rst_n = 1;

        // ---- Insert 4 prices OUT OF ORDER (bid book: higher price is better) ----
        do_op(100, 10); settle();
        do_op(102, 12); settle();
        do_op( 99,  9); settle();
        do_op(101, 11); settle();
        dump("after-inserts");

        // Expect sorted descending across PE[0..3], rest empty.
        check_pe("sorted", 0, 1'b1, 102, 12);
        check_pe("sorted", 1, 1'b1, 101, 11);
        check_pe("sorted", 2, 1'b1, 100, 10);
        check_pe("sorted", 3, 1'b1,  99,  9);
        check_pe("sorted", 4, 1'b0,   0,  0);
        check_tob("sorted", 102, 12);

        // ---- Delete the level at PE[1] (price 101) ----
        do_op(101, 0); settle();
        dump("after-delete");

        // Expect the gap healed: 100 and 99 pulled up by one, PE[3] now empty.
        check_pe("healed", 0, 1'b1, 102, 12);
        check_pe("healed", 1, 1'b1, 100, 10);
        check_pe("healed", 2, 1'b1,  99,  9);
        check_pe("healed", 3, 1'b0,   0,  0);
        check_tob("healed", 102, 12);  // top-of-book unaffected by the PE[1] delete

        if (errors == 0)
            $display("RESULT: PASS (4-way out-of-order sort + PE[1] delete pull-up heal)");
        else
            $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end

    // Safety timeout so the sim never hangs.
    initial begin
        #50000;
        $error("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
