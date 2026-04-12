# Phase 1: Core IPC & Memory Infrastructure

## Overview
This phase lays the absolute foundation for the trading engine. Before we can perform any heavy mathematical inference or interface with the FPGA, we must establish a zero-latency, cross-process communication layer. 

The goal is to allow the Asynchronous Data Ingestion process (which handles the ERCOT telemetry) to send data to the Inference/Trading process seamlessly, without ever blocking the CPU via OS-level mutexes or locks.

## Core Concepts & Technologies

### 1. POSIX Shared Memory (`shm_open`, `mmap`)
Instead of sending data via sockets or pipes (which involve kernel overhead and data serialization), we will map a single block of physical RAM into the virtual address space of both processes.
*   **Producer Process:** Writes directly to the memory block.
*   **Consumer Process:** Reads directly from the same exact memory block.
*   **Result:** True Zero-Copy data transfer.

### 2. The Lock-Free C++ Ring Buffer (SPSC Queue)
Because both processes access the same memory concurrently, we need a way to prevent race conditions. Standard `std::mutex` operations force the thread to sleep in the kernel if the resource is locked. We cannot afford microscopic context switches.
*   We will implement a Single-Producer, Single-Consumer (SPSC) lock-free ring buffer directly inside the shared memory block.
*   We will control concurrency using pure atomic constraints: `std::atomic<size_t>` with `memory_order_release` (for the producer) and `memory_order_acquire` (for the consumer).

### 3. Cache-Line Optimization (Avoiding False Sharing)
Modern CPUs pull RAM into the L1 cache in 64-byte chunks ("cache lines"). If the Producer's "write index" and the Consumer's "read index" live in the same 64-byte chunk, the CPU cores will constantly invalidate each other's cache, causing catastrophic latency.
*   We will explicitly pad our structs with `alignas(64)` to guarantee the read and write atomic pointers sit on entirely different cache lines.

## Implementation Steps (The Blueprint)

### Step 1: Project Scaffolding
*   Set up the `CMakeLists.txt` configured for pure POSIX C++20.
*   Define the directory structure (`/include`, `/src`, `/tests`).
*   Ensure linker flags include `-lrt` for POSIX real-time extensions (required for `shm_open` on some systems) and `-pthread`.

### Step 2: The Data Structures
*   Define the `ErcotTelemetry` struct. This will represent the physical data we are passing (e.g., Grid Frequency, Nodal Pricing, Wind Speed). This needs to be a standard-layout C++ struct containing plain data (floats, integers, timestamps) with no dynamic memory (no `std::vector` or `std::string`) so it can live in shared memory safely.

### Step 3: The Lock-Free SPSC Queue
*   Implement `LockFreeQueue<T, Capacity>`.
*   Include the `alignas(64) std::atomic<size_t> head_` and `alignas(64) std::atomic<size_t> tail_`.
*   Implement the `.push()` and `.pop()` methods utilizing strict memory ordering.

### Step 4: The Shared Memory Manager
*   Implement the C++ wrapper that calls `shm_open(...)`, configures the size with `ftruncate(...)`, and maps the lock-free queue directly into that memory using a placement-new `mmap(...)`.

### Step 5: Integration Testing
*   Write a simple `producer.cpp` that generates dummy 60Hz deviation ticks and pushes them to the queue.
*   Write a `consumer.cpp` that spins on the queue, popping the ticks.
*   Benchmark the latency from enqueue to dequeue in nanoseconds.

## Success Criteria for Phase 1
By the end of this phase, you should be able to spin up two completely separate compiled terminal processes, where one continuously streams dummy ERCOT data at high speeds, and the other reads it instantly, all communicating over a lock-free buffer in RAM with zero kernel intervention. This establishes the very same patterns required for both the ingestion pipeline and the future Egress to the hardware via Kernel-Bypass.