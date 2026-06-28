`timescale 1ns/1ps
// Systolic-array Limit Order Book: a chain of DEPTH lob_pe cells that keeps a fully
// sorted, compact book with the best price pinned at PE[0] (= top-of-book).
//
// All operations enter the head (PE[0].in_left) as a single (price, vol) order:
//   insert/update -> vol > 0 ;  delete -> vol == 0  (self-routes by price).
// Inserts ripple RIGHT (shove-down); deletes pull data LEFT behind a rightward
// collapse wave (gap-heal). Each ripples one PE/cycle, so top-of-book is always
// readable in O(1) regardless of depth.
//
// Wiring (per the systolic dataflow):
//   out_right[N] -> in_left[N+1]      (rightward: orders + collapse waves)
//   out_left[N+1] -> in_right[N]      (leftward: advertised contents for pull-up)
// The last cell's in_right is tied empty (no neighbor -> collapse wave terminates);
// its out_right is the overflow tap (worst level drops on a full-array insert).
module lob_array #(
    parameter int DEPTH   = 16,
    parameter int PRICE_W = 32,
    parameter int VOL_W   = 32,
    parameter bit IS_BID  = 1'b1
) (
    input  logic               clk,
    input  logic               rst_n,

    // Operation input (enters the head of the array).
    input  logic               in_valid,
    input  logic [PRICE_W-1:0] in_price,
    input  logic [VOL_W-1:0]   in_vol,

    // Top-of-book tap (= PE[0] contents).
    output logic               tob_valid,
    output logic [PRICE_W-1:0] tob_price,
    output logic [VOL_W-1:0]   tob_vol,

    // Full sorted book read-out (level i = PE[i]), flattened for indexed access.
    output logic [DEPTH-1:0]         book_occupied,
    output logic [DEPTH*PRICE_W-1:0] book_price,
    output logic [DEPTH*VOL_W-1:0]   book_vol
);

    // Inter-PE channels. Index i feeds PE[i]; index i+1 is driven by PE[i] / the
    // right neighbor. Indices [0] and [DEPTH] are the array boundaries.
    logic               r_valid    [DEPTH:0];  // rightward: order/collapse valid
    logic               r_collapse [DEPTH:0];  // rightward: 1 = collapse wave
    logic [PRICE_W-1:0] r_price    [DEPTH:0];
    logic [VOL_W-1:0]   r_vol      [DEPTH:0];

    logic               l_occupied [DEPTH:0];  // leftward: advertised contents
    logic [PRICE_W-1:0] l_price    [DEPTH:0];
    logic [VOL_W-1:0]   l_vol      [DEPTH:0];

    // Head boundary: external ops are always orders (never collapse).
    assign r_valid[0]    = in_valid;
    assign r_collapse[0] = 1'b0;
    assign r_price[0]    = in_price;
    assign r_vol[0]      = in_vol;

    // Tail boundary: no right neighbor -> a pull sees "empty", terminating collapse.
    assign l_occupied[DEPTH] = 1'b0;
    assign l_price[DEPTH]    = '0;
    assign l_vol[DEPTH]      = '0;

    genvar i;
    generate
        for (i = 0; i < DEPTH; i++) begin : g_pe
            lob_pe #(.PRICE_W(PRICE_W), .VOL_W(VOL_W), .IS_BID(IS_BID)) pe (
                .clk(clk), .rst_n(rst_n),
                // rightward in / out
                .in_left_valid       (r_valid[i]),
                .in_left_is_collapse (r_collapse[i]),
                .in_left_price       (r_price[i]),
                .in_left_vol         (r_vol[i]),
                .out_right_valid       (r_valid[i+1]),
                .out_right_is_collapse (r_collapse[i+1]),
                .out_right_price       (r_price[i+1]),
                .out_right_vol         (r_vol[i+1]),
                // leftward in (right neighbor) / out (to left neighbor)
                .in_right_occupied (l_occupied[i+1]),
                .in_right_price    (l_price[i+1]),
                .in_right_vol      (l_vol[i+1]),
                .out_left_occupied (l_occupied[i]),
                .out_left_price    (l_price[i]),
                .out_left_vol      (l_vol[i]),
                // state taps unused at array level (probed hierarchically in TB)
                .occupied(), .price(), .vol()
            );
        end
    endgenerate

    // Top-of-book is PE[0]'s advertised contents.
    assign tob_valid = l_occupied[0];
    assign tob_price = l_price[0];
    assign tob_vol   = l_vol[0];

    // Flatten the per-level advertised contents into the book read-out.
    genvar j;
    generate
        for (j = 0; j < DEPTH; j++) begin : g_book
            assign book_occupied[j]                 = l_occupied[j];
            assign book_price[j*PRICE_W +: PRICE_W] = l_price[j];
            assign book_vol[j*VOL_W +: VOL_W]       = l_vol[j];
        end
    endgenerate

endmodule
