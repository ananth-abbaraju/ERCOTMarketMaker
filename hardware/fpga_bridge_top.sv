`timescale 1ns/1ps
// Board-top for the FPGA <-> Mac UART bridge. Wires the full fast-path:
//
//   i_uart_rx -> uart_rx -> mdp3_parser ----\
//                              ^             |  (decoder gates the parser so it only
//                              | o_parser_valid  sees header bytes, never payload)
//                              |             v
//                           mdp3_payload_decoder -> lob_array -> tob_serializer
//                                                        |              |
//                                                     (best lvl)     uart_tx -> o_uart_tx
//
// One book side (bid by default). The market-data ingress lives on the Mac; this module
// is the deterministic hardware fast-path that parses MDP 3.0, maintains the sorted book,
// and streams top-of-book updates back over UART.
module fpga_bridge_top #(
    parameter int    CLKS_PER_BIT    = 868,    // 100 MHz / 115200 baud
    parameter int    DEPTH           = 16,
    parameter int    PRICE_W         = 64,     // CME SBE price is an int64 mantissa
    parameter int    VOL_W           = 32,
    parameter bit    IS_BID          = 1'b1,
    parameter [15:0] MSG_INCREMENTAL = 16'd46
) (
    input  logic clk,
    input  logic rst_n,
    input  logic i_uart_rx,
    output logic o_uart_tx
);

    // ---- UART RX ----
    logic       rx_valid;
    logic [7:0] rx_byte;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .i_rx(i_uart_rx),
        .o_valid(rx_valid), .o_byte(rx_byte)
    );

    // ---- Header parser (gated by the payload decoder) ----
    logic        parser_valid;   // = decoder.o_parser_valid
    logic        hdr_valid;
    logic [15:0] msg_type;
    logic [31:0] seq_num, instrument_id;
    logic [63:0] timestamp;
    logic [15:0] payload_len;

    mdp3_parser u_parser (
        .clk(clk), .rst_n(rst_n),
        .in_valid(parser_valid), .in_byte(rx_byte),
        .out_valid(hdr_valid), .msg_type(msg_type),
        .seq_num(seq_num), .instrument_id(instrument_id),
        .timestamp(timestamp), .payload_len(payload_len)
    );

    // ---- SBE payload decoder -> (price, vol) ----
    logic               order_valid;
    logic [PRICE_W-1:0] order_price;
    logic [VOL_W-1:0]   order_vol;

    mdp3_payload_decoder #(
        .PRICE_W(PRICE_W), .VOL_W(VOL_W), .MSG_INCREMENTAL(MSG_INCREMENTAL)
    ) u_decoder (
        .clk(clk), .rst_n(rst_n),
        .in_valid(rx_valid), .in_byte(rx_byte),
        .hdr_valid(hdr_valid), .msg_type(msg_type), .payload_len(payload_len),
        .o_parser_valid(parser_valid),
        .o_valid(order_valid), .o_price(order_price), .o_vol(order_vol)
    );

    // ---- Systolic LOB ----
    logic               tob_valid;
    logic [PRICE_W-1:0] tob_price;
    logic [VOL_W-1:0]   tob_vol;

    lob_array #(.DEPTH(DEPTH), .PRICE_W(PRICE_W), .VOL_W(VOL_W), .IS_BID(IS_BID)) u_book (
        .clk(clk), .rst_n(rst_n),
        .in_valid(order_valid), .in_price(order_price), .in_vol(order_vol),
        .tob_valid(tob_valid), .tob_price(tob_price), .tob_vol(tob_vol),
        .book_occupied(), .book_price(), .book_vol()
    );

    // ---- Top-of-book serializer + UART TX ----
    logic       tx_start, tx_busy, tx_done;
    logic [7:0] tx_byte;

    tob_serializer #(.PRICE_W(PRICE_W), .VOL_W(VOL_W)) u_ser (
        .clk(clk), .rst_n(rst_n),
        .tob_valid(tob_valid), .tob_price(tob_price), .tob_vol(tob_vol),
        .i_tx_busy(tx_busy), .i_tx_done(tx_done),
        .o_tx_start(tx_start), .o_tx_byte(tx_byte)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .i_start(tx_start), .i_byte(tx_byte),
        .o_serial(o_uart_tx), .o_busy(tx_busy), .o_done(tx_done)
    );

endmodule
