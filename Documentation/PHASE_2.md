# Phase 2: FPGA Hardware Fast-Path & Ingress

## Overview
Now that the software communication layer is capable of handling gigabytes of data with nanosecond precision, we must build the actual hardware ingestion pipeline.

In traditional systems, market data (like CME MDP 3.0 ticks) passes through a Network Interface Card (NIC), traverses the Linux kernel network stack (TCP/IP), triggers a hardware interrupt, and finally reaches the application space. For High-Frequency Trading, this is too slow.

In Phase 2, we are turning a Digilent Basys 3 FPGA into a highly specialized, deterministic trading NIC. It will parse binary market packets on the fly, manage a sorted Limit Order Book in hardware $O(1)$ time, and blast signals directly to our C++ engine using Kernel-Bypass Networking.

## Core Concepts & Technologies

### 1. CME MDP 3.0 Parser (SystemVerilog)
The Chicago Mercantile Exchange (CME) Market Data Platform (MDP 3.0) sends packetized binary data.
*   We will design a Verilog State Machine that reads the incoming bytes, parses the message headers (MsgType, TemplateID), and extracts the `Price`, `Quantity`, and `Side` (Bid/Ask) entirely in hardware logic.
*   This strips away all networking overhead before the data even touches our software.

### 2. Systolic Array Limit Order Book (LOB)
Instead of maintaining the order book in a software array or a basic FPGA BRAM hash map (which requires looping or sorting), we will use a **Systolic Array**.
*   A Systolic Array is a grid of processing elements (PEs) that asynchronously pass data to their neighbors on every clock cycle.
*   When a new CME limit order arrives, it flows through the array. The hardware organically "pushes" worse prices down the chain, maintaining a perfectly sorted book in true $O(1)$ hardware clock cycles, regardless of book depth.

### 3. Kernel-Bypass Networking (PMOD High-Speed Interface)
We cannot use the standard UART (USB-Serial) bridge on the Basys 3, as its baud rate introduces microsecond-level latency constraints.
*   We will re-purpose the high-speed PMOD headers on the FPGA to act as a custom parallel or high-speed serial bus (e.g., interfacing with a dedicated Ethernet PHY or USB 3.0 FIFO).
*   The FPGA will write the parsed LOB state and triggering events out of this port. 
*   Our C++ host will memory-map the destination buffer (just like we did in Phase 1) and run a zero-OS-interrupt user-space polling loop to instantly read the hardware's output.

## Implementation Steps (The Blueprint)

### Step 1: Vivado Project Setup
*   Create the master `top.v` module for the Basys 3.
*   Configure the clock wizard (e.g., taking the 100MHz onboard clock and generating necessary internal clocks for the PMOD interface).

### Step 2: The MDP 3.0 Packet Parser
*   Define the SystemVerilog states: `WAIT_SYNC`, `READ_HEADER`, `EXTRACT_PAYLOAD`, `ERROR_RECOVERY`.
*   Write the testbench (`tb_mdp3_parser.v`) that feeds simulated CME hex bytes into the module to verify accurate extraction of the pricing data without clock stall.

### Step 3: The Systolic Array LOB Module
*   Define a basic Processing Element (PE) module. A single PE stores one price level (Price, Volume).
*   Chain 8 or 16 PEs together.
*   Write the combinational logic that compares the incoming CME price to the current PE's price, and decides whether to absorb the new order, pass it to the next PE, or shift the current value down.

### Step 4: The Kernel-Bypass PMOD Controller
*   Write the interface driver in Verilog that takes the output of the Systolic Array (e.g., the current Top-of-Book Bid/Ask) and serializes it out of the PMOD pins at maximum clock frequency.

## Success Criteria for Phase 2
Phase 2 is considered complete when a Vivado ModelSim testbench can inject a binary CME MDP 3.0 packet into the FPGA design, the Systolic Array correctly updates the top-of-book price in $O(1)$ clock cycles, and the final state is blasted out of the PMOD output register without a single CPU cycle being wasted.