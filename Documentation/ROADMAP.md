# Project Roadmap: High-Frequency Trading Systems Architecture

This roadmap details the end-to-end development of a pure systems, hardware-software co-designed Quant Trading Engine. It focuses on bare-metal Linux/POSIX compliance, zero-copy lock-free IPC, FPGA hardware execution, and cache-localized SIMD-accelerated machine learning.

## Phase 1: Core IPC & Memory Infrastructure (The Foundation)
**Goal:** Establish the zero-latency communication layer between the ingestion processes, the inference engine, and the hardware bridge.
*   **POSIX Shared Memory:** Implement `shm_open` and `mmap` to allocate cross-process memory boundaries.
*   **Lock-Free Circular Buffers:** Design SPSC (Single-Producer Single-Consumer) queues using `std::atomic` and explicit memory barriers (`memory_order_acquire` / `memory_order_release`) to eliminate mutex blocking.
*   **Cache-Line Alignment:** Struct definitions (Struct of Arrays vs Array of Structs) hardcoded to 64-byte boundaries to prevent false sharing in the CPU L1/L2 cache.

## Phase 2: FPGA Hardware Fast-Path & Ingress (SystemVerilog)
**Goal:** Mimic a 10GbE network card's logic using the Basys 3 FPGA to handle deterministic data parsing.
*   **L2 Market Data Ingestion:** Write SystemVerilog modules to parse simulated CME MDP 3.0 (Market Data Platform 3.0) binary protocol headers for energy futures.
*   **Systolic Array Limit Order Book (LOB):** Abandon standard arrays or BRAM hash maps. Implement a hardware Systolic Array (similar to Google TPUs) on the FPGA to maintain a fully sorted LOB and calculate the weighted mid-price in true $O(1)$ hardware clock cycles, regardless of book depth.
*   **User-Space Polling (Zero OS Interrupts):** Write a custom C++ driver that polls a memory-mapped ring buffer directly, completely bypassing the OS kernel network stack and saving microscopic context-switching overhead.
*   **Kernel-Bypass Networking** _(Deferred — Phase 2 extra step, currently limited by hardware; will address soon)_**:** Obliterate the UART bottleneck. Wire a high-speed interface (e.g., Ethernet PHY or high-speed USB 3.0 FIFO via PMOD ports) to stream data.

## Phase 3: Asynchronous Market Data Ingestion (C++)
**Goal:** Continuously ingest institutional-grade data and prepare it for inference without blocking the critical trading path.
*   **Thread-Pinned Workers:** Implement thread affinity to pin ingestion processes to specific CPU cores.
*   **Data Source: ERCOT Grid Telemetry (Time-Series Physics):** Ingest real-time Texas grid frequency (60Hz deviations), locational marginal pricing (LMP), and meteorological telemetry. Capitalize on continuous physical processes that govern power trading.
*   **SIMD Vectorization:** Use ARM NEON intrinsics (`<arm_neon.h>`) for High-Throughput Feature Normalization. Vectorize the rolling standard deviation and Z-score normalization of thousands of grid telemetry points per microsecond, flushing the normalized float arrays directly into the Lock-Free Circular Buffer.

## Phase 4: Ultra-Low Latency ML Inference Engine (The "Brain")
**Goal:** Execute heavy mathematical reranking and alpha generation entirely on the CPU using SIMD and strict cache-locality when the FPGA triggers an interrupt. 
**Status:** *Architecture to be finalized later in development. Options include:*

### Option A: Liquid Neural Networks (LNNs) / Continuous-Time AI
*   **The Concept:** Developed by MIT CSAIL, LNNs are continuous-time recurrent neural networks built on Ordinary Differential Equations (ODEs).
*   **The Quant Application:** Financial markets do not operate in perfectly spaced discrete time steps; tick data is highly asynchronous. An LNN continuously evolves its state based on the actual *time elapsed* between ticks, which perfectly aligns with the continuous physical data from the ERCOT grid.
*   **The Architecture Flex:** Implementing a lightweight Liquid Time-Constant (LTC) network in pure C++ using a custom SIMD-accelerated Runge-Kutta ODE solver. Pitched as: *"I built a continuous-time neural ODE solver in C++ because discrete-time models fail to accurately model the thermodynamic and temporal continuity of power grids."*

### Option B: Selective State Space Models (Mamba-inspired)
*   **The Concept:** State Space Models (SSMs) offer the reasoning capabilities of attention but with $O(1)$ inference time per step instead of $O(N^2)$.
*   **The Quant Application:** For HFT, recalculating attention over a long context window per tick is too slow. SSMs compress the entire history of the order book and grid frequency deviations into a hidden state vector that updates iteratively.
*   **The Architecture Flex:** A custom C++ inference engine for a micro-SSM. When the FPGA triggers a hardware interrupt, the engine performs a highly optimized, SIMD-accelerated Matrix-Vector multiplication to update the state and generate a signal in $O(1)$ time, never invalidating the L1 cache.

### Option C: The Neuromorphic FPGA Coprocessor (Hardware SNNs)
*   **The Concept:** Neuromorphic architecture where neurons communicate via discrete "spikes" (Leaky Integrate-and-Fire). Instead of the CPU, this is built entirely in SystemVerilog.
*   **The Quant Application:** Limit Order Books and sudden frequency dips are inherently event-driven. L2 tick data never goes to the CPU; the FPGA parses the MDP 3.0 packets and immediately translates them into "spikes."
*   **The Architecture Flex:** By merging memory and compute onto the FPGA fabric, you obliterate the von Neumann bottleneck. A massive sell wall or frequency perturbation triggers a spike cascade in your FPGA-based neural fabric, generating a trade signal in literal nanoseconds entirely in hardware. The C++ host simply logs the trades after the fact.

## Phase 5: Signal Generation & Hardware Execution
**Goal:** Combine inferences, generate a final signal, and execute safely through hardware.
*   **Alpha Generation:** Fast C++ strategy logic combining FPGA structured data (price spikes) with the CPU's ML inference (contextual state).
*   **Kernel-Bypass Egress:** Write the final `BUY/SELL` payload directly back into a shared memory buffer mapped to the high-speed PMOD interface (Ethernet PHY/USB 3.0), blasting it back to the FPGA without ever waking up the Linux kernel.
*   **FPGA Pre-Trade Risk Coprocessor:** A SystemVerilog module executing a 1-clock-cycle Risk Check against hardcoded position limits in BRAM to guarantee deterministic safety.
*   **Execution:** Final theoretical output signal generated by the FPGA.

## Phase 6: Profiling, Optimization & Benchmarking
*   Integration testing between the C++ lock-free buffers and the ML inference engine.
*   Cache-miss profiling using `Valgrind` / `perf`.
*   Latency benchmarking (nanosecond precision) across the whole round-trip (FPGA -> C++ -> ML -> C++ -> FPGA).
