Phase 2 — Task 1: L2 Market Data Ingestion (Header Parser)

Scope
- Implement header-level parsing for CME MDP 3.0 frames on FPGA (Basys 3). This task focuses on extracting header fields and validating basic framing; payload decoding is out-of-scope for now.

Interface
- clk (input): 100MHz reference clock
- rst_n (input): active-low reset
- in_valid (input): indicates in_byte is valid this cycle
- in_byte (input) [7:0]: incoming byte stream (big-endian fields assumed)
- out_valid (output): asserts when header fields are available
- msg_type (output) [15:0]
- seq_num (output) [31:0]
- instrument_id (output) [31:0]
- timestamp (output) [63:0]
- payload_len (output) [15:0]

Simulation
- Use scripts/run_sim.sh with Icarus Verilog for unit testing.

Notes
- Adjust endianness and field widths to match exact CME MDP 3.0 spec when full spec is integrated.
- For Basys 3 synthesis, keep logic minimal; prefer streaming and minimal buffering.
