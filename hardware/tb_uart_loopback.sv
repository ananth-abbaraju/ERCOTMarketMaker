`timescale 1ns/1ps
// Self-checking loopback testbench: uart_tx.o_serial -> uart_rx.i_rx.
// Sends a handful of bytes through the transmitter and verifies the receiver
// reconstructs each one. CLKS_PER_BIT is tiny so a byte takes a few dozen cycles.
module tb_uart_loopback();
    localparam int CLKS_PER_BIT = 8;

    logic clk, rst_n;

    // tx side
    logic       tx_start;
    logic [7:0] tx_byte;
    logic       serial;       // the "wire" between tx and rx
    logic       tx_busy, tx_done;

    // rx side
    logic       rx_valid;
    logic [7:0] rx_byte;

    int errors = 0;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx (
        .clk(clk), .rst_n(rst_n),
        .i_start(tx_start), .i_byte(tx_byte),
        .o_serial(serial), .o_busy(tx_busy), .o_done(tx_done)
    );

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx (
        .clk(clk), .rst_n(rst_n),
        .i_rx(serial),
        .o_valid(rx_valid), .o_byte(rx_byte)
    );

    // 100MHz clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Send one byte and wait for the receiver to present it; check it matches.
    task automatic send_check(input string tag, input logic [7:0] b);
        @(negedge clk);
        tx_byte  = b;
        tx_start = 1'b1;
        @(negedge clk);
        tx_start = 1'b0;

        // Wait for the receiver to flag a completed byte.
        @(posedge rx_valid);
        #1;
        if (rx_byte !== b) begin
            errors++;
            $error("[%s] rx_byte got 0x%02x exp 0x%02x", tag, rx_byte, b);
        end else begin
            $display("[%s] looped back 0x%02x OK", tag, rx_byte);
        end

        // Let the transmitter fully return to idle before the next byte.
        @(posedge tx_done);
        @(negedge clk);
    endtask

    initial begin
        rst_n = 0; tx_start = 0; tx_byte = '0;
        #20;
        rst_n = 1;
        @(negedge clk);

        send_check("b0", 8'h00);
        send_check("b1", 8'hFF);
        send_check("b2", 8'hA5);
        send_check("b3", 8'h3C);
        send_check("b4", 8'h81);

        if (errors == 0)
            $display("RESULT: PASS (uart tx->rx loopback of 5 bytes correct)");
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
