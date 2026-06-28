`timescale 1ns/1ps
// Bidirectional Limit Order Book Processing Element (PE) -- the unit cell of the
// systolic-array LOB. Holds exactly one price level (price, volume) and, on each
// clock, makes a local O(1) decision against traffic on two channels:
//
//   Rightward channel (in_left -> out_right, REGISTERED): orders and "collapse"
//     control waves flow toward higher index. Inserts move data this direction.
//   Leftward channel (in_right <- out_left, combinational): each PE continuously
//     advertises its current contents to its left neighbor so it can be pulled.
//     Deletes move data this direction (a gap heals by pulling from the right).
//
// Operation model (all ops enter the array head at PE[0].in_left as an order):
//   * INSERT/UPDATE (vol > 0): better -> evict & shove old right; worse -> pass
//     right; match -> overwrite volume; empty -> fill.
//   * DELETE (vol == 0): self-routes by price; on match the PE vacates by pulling
//     its right neighbor in immediately and emitting a COLLAPSE token rightward.
//     Each PE receiving COLLAPSE pulls its own right neighbor and forwards the
//     token, so the hole ripples right (1 PE/cycle) until it falls off the end.
//
// The collapse token is what makes pull-up correct: without it, a pulled-from PE
// would never know it was consumed and would keep a duplicate value.
//
// Side is parameterized: IS_BID=1 -> higher price better (bid); 0 -> lower (ask).
// Scope: one operation in flight at a time (no insert/collapse hazard arbitration).
module lob_pe #(
    parameter int PRICE_W = 32,
    parameter int VOL_W   = 32,
    parameter bit IS_BID  = 1'b1
) (
    input  logic               clk,
    input  logic               rst_n,

    // Rightward channel in (from left neighbor / array head).
    input  logic               in_left_valid,
    input  logic               in_left_is_collapse,
    input  logic [PRICE_W-1:0] in_left_price,
    input  logic [VOL_W-1:0]   in_left_vol,

    // Rightward channel out (to right neighbor), registered.
    output logic               out_right_valid,
    output logic               out_right_is_collapse,
    output logic [PRICE_W-1:0] out_right_price,
    output logic [VOL_W-1:0]   out_right_vol,

    // Leftward channel in (right neighbor's advertised contents, for pull-up).
    input  logic               in_right_occupied,
    input  logic [PRICE_W-1:0] in_right_price,
    input  logic [VOL_W-1:0]   in_right_vol,

    // Leftward channel out (our contents, advertised to the left neighbor).
    output logic               out_left_occupied,
    output logic [PRICE_W-1:0] out_left_price,
    output logic [VOL_W-1:0]   out_left_vol,

    // Stored level -- the top-of-book tap when this is PE[0].
    output logic               occupied,
    output logic [PRICE_W-1:0] price,
    output logic [VOL_W-1:0]   vol
);

    // Advertise current contents to the left (combinational mirror of state).
    assign out_left_occupied = occupied;
    assign out_left_price    = price;
    assign out_left_vol      = vol;

    // Incoming-order classification (only meaningful while occupied).
    wire order_in    = in_left_valid && !in_left_is_collapse;
    wire collapse_in = in_left_valid &&  in_left_is_collapse;
    wire better      = IS_BID ? (in_left_price > price) : (in_left_price < price);
    wire match       = (in_left_price == price);

    // A delete (order with vol==0) that matches our level vacates this PE -- handled
    // by the same pull-from-right path as an incoming collapse token.
    wire delete_match = order_in && occupied && match && (in_left_vol == '0);
    wire do_collapse  = collapse_in || delete_match;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occupied              <= 1'b0;
            price                 <= '0;
            vol                   <= '0;
            out_right_valid       <= 1'b0;
            out_right_is_collapse <= 1'b0;
            out_right_price       <= '0;
            out_right_vol         <= '0;
        end else begin
            // Default: nothing emitted rightward unless a case below overrides.
            out_right_valid       <= 1'b0;
            out_right_is_collapse <= 1'b0;
            out_right_price       <= '0;
            out_right_vol         <= '0;

            if (do_collapse) begin
                // PULL-UP: take the right neighbor's contents. If it had a value, the
                // hole must keep moving -> forward the collapse token. If the right was
                // empty, we simply become empty and the wave dies here.
                occupied <= in_right_occupied;
                price    <= in_right_price;
                vol      <= in_right_vol;
                if (in_right_occupied) begin
                    out_right_valid       <= 1'b1;
                    out_right_is_collapse <= 1'b1;
                end
            end else if (order_in) begin
                if (!occupied) begin
                    // EMPTY: fill on a real order; a delete-miss (vol==0) is a no-op.
                    if (in_left_vol != '0) begin
                        occupied <= 1'b1;
                        price    <= in_left_price;
                        vol      <= in_left_vol;
                    end
                end else if (match) begin
                    // OVERWRITE (vol>0; vol==0 was routed to do_collapse above).
                    vol <= in_left_vol;
                end else if (better && (in_left_vol != '0)) begin
                    // EVICT / SHOVE DOWN: take incoming, push old level right.
                    // Guarded by vol!=0 so a delete-miss (vol==0 for an absent price)
                    // never inserts a phantom level -- it just rides past.
                    out_right_valid <= 1'b1;
                    out_right_price <= price;
                    out_right_vol   <= vol;
                    price           <= in_left_price;
                    vol             <= in_left_vol;
                end else begin
                    // WORSE / PASS THROUGH (or a vol==0 delete-miss riding past a
                    // better level): keep our level, forward the order right.
                    out_right_valid <= 1'b1;
                    out_right_price <= in_left_price;
                    out_right_vol   <= in_left_vol;
                end
            end
            // else: idle -> hold state.
        end
    end

endmodule
