`timescale 1ns/1ps
// Integration testbench for fpga_bridge_top -- the whole fast-path in one sim:
//   TB uart_tx -> dut.i_uart_rx -> parse -> decode -> lob_array -> serialize
//             -> dut.o_uart_tx -> TB uart_rx (monitor) -> 14-byte tob frame check.
//
// Scenario (bid book, higher price is better):
//   insert 100/10  -> tob 100/10  -> frame #0
//   insert 105/20  -> tob 105/20  -> frame #1
//   insert 103/5   -> tob unchanged (105 still best) -> NO frame
//   delete 105     -> tob heals to 103/5 -> frame #2
// Each returned frame's price/vol and XOR checksum are verified.
module tb_fpga_bridge_top();
    localparam int    CLKS_PER_BIT    = 8;
    localparam int    DEPTH           = 8;
    localparam int    PRICE_W         = 64;
    localparam int    VOL_W           = 32;
    localparam [15:0] MSG_INCREMENTAL = 16'd46;

    logic clk, rst_n;
    logic feed_serial;   // TB feeder -> dut RX
    logic dut_tx;        // dut TX -> TB monitor

    int errors = 0;

    // ---- DUT ----
    fpga_bridge_top #(
        .CLKS_PER_BIT(CLKS_PER_BIT), .DEPTH(DEPTH),
        .PRICE_W(PRICE_W), .VOL_W(VOL_W), .IS_BID(1'b1),
        .MSG_INCREMENTAL(MSG_INCREMENTAL)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .i_uart_rx(feed_serial), .o_uart_tx(dut_tx)
    );

    // ---- TB feeder (drives the DUT's RX line) ----
    logic       feed_start, feed_busy, feed_done;
    logic [7:0] feed_byte;
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) feeder (
        .clk(clk), .rst_n(rst_n),
        .i_start(feed_start), .i_byte(feed_byte),
        .o_serial(feed_serial), .o_busy(feed_busy), .o_done(feed_done)
    );

    // ---- TB monitor (reads the DUT's TX line) ----
    logic       mon_valid;
    logic [7:0] mon_byte;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) monitor (
        .clk(clk), .rst_n(rst_n),
        .i_rx(dut_tx),
        .o_valid(mon_valid), .o_byte(mon_byte)
    );

    // 100MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ---- Monitor frame collector: hunt 0xAA, gather 14 bytes, record price/vol ----
    logic [7:0] rxbuf [0:13];
    int         rxcnt;
    logic       hunting;
    int         got_frames;
    int         csum_fails;
    logic [63:0] hist_price [0:7];
    logic [31:0] hist_vol   [0:7];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxcnt <= 0; hunting <= 1'b1; got_frames <= 0; csum_fails <= 0;
        end else if (mon_valid) begin
            if (hunting) begin
                if (mon_byte == 8'hAA) begin
                    rxbuf[0] <= 8'hAA;
                    rxcnt   <= 1;
                    hunting <= 1'b0;
                end
            end else begin
                rxbuf[rxcnt] <= mon_byte;
                if (rxcnt == 13) begin
                    // Frame complete; rxbuf[1..12] already latched, mon_byte = checksum.
                    logic [7:0] cs;
                    cs = 8'h00;
                    for (int k = 1; k <= 12; k++) cs ^= rxbuf[k];
                    if (cs !== mon_byte) csum_fails <= csum_fails + 1;
                    hist_price[got_frames] <= {rxbuf[1], rxbuf[2], rxbuf[3], rxbuf[4],
                                               rxbuf[5], rxbuf[6], rxbuf[7], rxbuf[8]};
                    hist_vol[got_frames]   <= {rxbuf[9], rxbuf[10], rxbuf[11], rxbuf[12]};
                    got_frames <= got_frames + 1;
                    hunting    <= 1'b1;
                    rxcnt      <= 0;
                end else begin
                    rxcnt <= rxcnt + 1;
                end
            end
        end
    end

    // Send one byte through the TB feeder.
    task automatic feed_send(input logic [7:0] b);
        @(negedge clk);
        feed_byte  = b;
        feed_start = 1'b1;
        @(negedge clk);
        feed_start = 1'b0;
        @(posedge feed_done);
        @(negedge clk);
    endtask

    // Push a 32-byte frame (20-byte header, payload_len=12, then price+vol).
    task automatic send_frame(input logic [15:0] mtype,
                              input logic [63:0] price, input logic [31:0] vol);
        feed_send(mtype[15:8]);  feed_send(mtype[7:0]);
        feed_send(8'h00); feed_send(8'h00); feed_send(8'h00); feed_send(8'h01);
        feed_send(8'h00); feed_send(8'h00); feed_send(8'h00); feed_send(8'h2A);
        feed_send(8'h00); feed_send(8'h00); feed_send(8'h00); feed_send(8'h00);
        feed_send(8'h00); feed_send(8'h00); feed_send(8'h00); feed_send(8'h00);
        feed_send(8'h00); feed_send(8'h0C);
        feed_send(price[63:56]); feed_send(price[55:48]); feed_send(price[47:40]); feed_send(price[39:32]);
        feed_send(price[31:24]); feed_send(price[23:16]); feed_send(price[15:8]);  feed_send(price[7:0]);
        feed_send(vol[31:24]);   feed_send(vol[23:16]);   feed_send(vol[15:8]);    feed_send(vol[7:0]);
    endtask

    // Wait for the monitor to reach a target frame count (with timeout).
    task automatic wait_frames(input int target);
        int guard;
        guard = 0;
        while (got_frames < target && guard < 20000) begin
            @(posedge clk); guard++;
        end
    endtask

    initial begin
        rst_n = 0; feed_start = 0; feed_byte = 0;
        #20;
        rst_n = 1;
        @(negedge clk);

        send_frame(MSG_INCREMENTAL, 64'd100, 32'd10);  wait_frames(1);
        send_frame(MSG_INCREMENTAL, 64'd105, 32'd20);  wait_frames(2);
        send_frame(MSG_INCREMENTAL, 64'd103, 32'd5);   // no tob change -> no frame
        repeat (2000) @(posedge clk);
        send_frame(MSG_INCREMENTAL, 64'd105, 32'd0);   // delete best -> heal to 103/5
        wait_frames(3);
        repeat (200) @(posedge clk);

        if (got_frames !== 3) begin
            errors++; $error("expected 3 tob frames, got %0d", got_frames);
        end
        if (csum_fails !== 0) begin
            errors++; $error("checksum failures: %0d", csum_fails);
        end

        // Frame #0: 100/10
        if (got_frames > 0 && (hist_price[0] !== 64'd100 || hist_vol[0] !== 32'd10)) begin
            errors++; $error("frame0 got %0d/%0d exp 100/10", hist_price[0], hist_vol[0]);
        end
        // Frame #1: 105/20
        if (got_frames > 1 && (hist_price[1] !== 64'd105 || hist_vol[1] !== 32'd20)) begin
            errors++; $error("frame1 got %0d/%0d exp 105/20", hist_price[1], hist_vol[1]);
        end
        // Frame #2: 103/5 (after deleting the best level)
        if (got_frames > 2 && (hist_price[2] !== 64'd103 || hist_vol[2] !== 32'd5)) begin
            errors++; $error("frame2 got %0d/%0d exp 103/5", hist_price[2], hist_vol[2]);
        end

        if (errors == 0) begin
            $display("frames: 100/10, 105/20, 103/5 (all checksums OK)");
            $display("RESULT: PASS (full RX->parse->decode->LOB->serialize->TX loop)");
        end else
            $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end

    // Safety timeout so the sim never hangs.
    initial begin
        #2000000;
        $error("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
