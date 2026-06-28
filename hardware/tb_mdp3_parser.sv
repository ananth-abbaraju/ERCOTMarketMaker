`timescale 1ns/1ps
// Self-checking testbench for mdp3_parser.
//
// Two scenarios:
//   A. Two frames separated by an idle gap   -> verifies field extraction + re-arm.
//   B. Two frames back-to-back (zero gap)     -> verifies no byte is dropped when a
//                                                new frame starts the same cycle the
//                                                previous frame completes.
module tb_mdp3_parser();
    logic        clk;
    logic        rst_n;
    logic        in_valid;
    logic [7:0]  in_byte;

    logic        out_valid;
    logic [15:0] msg_type;
    logic [31:0] seq_num;
    logic [31:0] instrument_id;
    logic [63:0] timestamp;
    logic [15:0] payload_len;

    int errors = 0;

    mdp3_parser uut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_byte(in_byte),
        .out_valid(out_valid), .msg_type(msg_type), .seq_num(seq_num),
        .instrument_id(instrument_id), .timestamp(timestamp), .payload_len(payload_len)
    );

    // 100MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ---- Frame capture monitor ----
    // out_valid and the field outputs are all registered, so sampling them together
    // on posedge is self-consistent (no clock-skew race). Each completed frame is
    // recorded so the stimulus and checking stay decoupled from exact cycle timing.
    localparam int MAX_FRAMES = 8;
    logic [15:0] cap_msg  [0:MAX_FRAMES-1];
    logic [31:0] cap_seq  [0:MAX_FRAMES-1];
    logic [31:0] cap_inst [0:MAX_FRAMES-1];
    logic [63:0] cap_ts   [0:MAX_FRAMES-1];
    logic [15:0] cap_len  [0:MAX_FRAMES-1];
    int cap_count = 0;
    int chk_index = 0;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            cap_msg [cap_count] <= msg_type;
            cap_seq [cap_count] <= seq_num;
            cap_inst[cap_count] <= instrument_id;
            cap_ts  [cap_count] <= timestamp;
            cap_len [cap_count] <= payload_len;
            cap_count           <= cap_count + 1;
        end
    end

    // Stream bytes one per clock. drop_tail=1 deasserts in_valid afterwards (idle
    // gap); drop_tail=0 leaves the stream hot so the next send is truly contiguous.
    task automatic send_bytes(input logic [7:0] data [], input bit drop_tail = 1);
        foreach (data[i]) begin
            @(posedge clk);
            in_valid <= 1'b1;
            in_byte  <= data[i];
        end
        if (drop_tail) begin
            @(posedge clk);
            in_valid <= 1'b0;
            in_byte  <= 8'h00;
        end
    endtask

    // Compare the next captured frame against expected values.
    task automatic expect_frame(
        input string         tag,
        input logic [15:0]   e_msg,
        input logic [31:0]   e_seq,
        input logic [31:0]   e_inst,
        input logic [63:0]   e_ts,
        input logic [15:0]   e_len
    );
        if (chk_index >= cap_count) begin
            errors++;
            $error("[%s] expected a frame but none was captured", tag);
            return;
        end
        if (cap_msg [chk_index] !== e_msg)  begin errors++; $error("[%s] msg_type  got %h exp %h", tag, cap_msg [chk_index], e_msg);  end
        if (cap_seq [chk_index] !== e_seq)  begin errors++; $error("[%s] seq_num   got %h exp %h", tag, cap_seq [chk_index], e_seq);  end
        if (cap_inst[chk_index] !== e_inst) begin errors++; $error("[%s] inst_id   got %h exp %h", tag, cap_inst[chk_index], e_inst); end
        if (cap_ts  [chk_index] !== e_ts)   begin errors++; $error("[%s] timestamp got %h exp %h", tag, cap_ts  [chk_index], e_ts);   end
        if (cap_len [chk_index] !== e_len)  begin errors++; $error("[%s] payload   got %h exp %h", tag, cap_len [chk_index], e_len);  end
        $display("[%s] msg=%h seq=%h inst=%h ts=%h len=%h", tag,
                 cap_msg[chk_index], cap_seq[chk_index], cap_inst[chk_index],
                 cap_ts[chk_index], cap_len[chk_index]);
        chk_index++;
    endtask

    logic [7:0] frame1 [];
    logic [7:0] frame2 [];

    initial begin
        rst_n    = 0;
        in_valid = 0;
        in_byte  = 0;
        #20;
        rst_n = 1;

        // Frame 1: msg=0x0102 seq=0x00000005 inst=0x0000ABCD
        //          ts=0x00000163ABCDEF12 len=0x0010
        frame1 = '{8'h01,8'h02, 8'h00,8'h00,8'h00,8'h05, 8'h00,8'h00,8'hAB,8'hCD,
                   8'h00,8'h00,8'h01,8'h63,8'hAB,8'hCD,8'hEF,8'h12, 8'h00,8'h10};

        // Frame 2: distinct values to confirm a clean re-arm.
        //          msg=0xBEEF seq=0x12345678 inst=0xCAFEBABE
        //          ts=0xDEADBEEF00112233 len=0x0040
        frame2 = '{8'hBE,8'hEF, 8'h12,8'h34,8'h56,8'h78, 8'hCA,8'hFE,8'hBA,8'hBE,
                   8'hDE,8'hAD,8'hBE,8'hEF,8'h00,8'h11,8'h22,8'h33, 8'h00,8'h40};

        // Scenario A: frames separated by an idle gap.
        send_bytes(frame1);
        repeat (5) @(posedge clk);
        send_bytes(frame2);

        repeat (3) @(posedge clk);  // small gap before scenario B

        // Scenario B: frames back-to-back with NO idle cycle in between
        // (frame1 keeps the stream hot, frame2 begins immediately).
        send_bytes(frame1, 0);
        send_bytes(frame2, 1);

        repeat (3) @(posedge clk);  // let the final out_valid reach the monitor

        // Expected capture sequence: A{f1,f2}, B{f1,f2}.
        expect_frame("A.frame1", 16'h0102, 32'h00000005, 32'h0000ABCD, 64'h00000163ABCDEF12, 16'h0010);
        expect_frame("A.frame2", 16'hBEEF, 32'h12345678, 32'hCAFEBABE, 64'hDEADBEEF00112233, 16'h0040);
        expect_frame("B.frame1", 16'h0102, 32'h00000005, 32'h0000ABCD, 64'h00000163ABCDEF12, 16'h0010);
        expect_frame("B.frame2", 16'hBEEF, 32'h12345678, 32'hCAFEBABE, 64'hDEADBEEF00112233, 16'h0040);

        if (cap_count != 4) begin
            errors++;
            $error("expected exactly 4 frames, captured %0d", cap_count);
        end

        if (errors == 0)
            $display("RESULT: PASS (4 frames incl. back-to-back, all fields correct)");
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
