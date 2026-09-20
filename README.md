# ERCOT Market Maker

A hardware/software co-designed, HFT-style research engine. It ingests simulated CME MDP 3.0
market data through an FPGA fast path and live ERCOT (Texas grid) telemetry through an async
C++ client, wires the stages together with lock-free shared-memory IPC, and emits a
Buy/Sell/Hold signal.

**Scope:** a research and verification project, not a trading system. It emits directional
signals rather than two-sided quotes, and no predictive value is claimed.

## Architecture

Separate processes, wired by single-producer/single-consumer lock-free queues in POSIX shared memory.

| Phase | What | Where |
|-------|------|-------|
| 1 | Lock-free SPSC ring buffer over POSIX shared memory, 64-byte cache-line aligned | `include/ipc/` |
| 2 | SystemVerilog MDP 3.0 / SBE decoder feeding a systolic-array limit order book with O(1) top-of-book reads | `hardware/` |
| 2.5 | Host-side UART bridge: frame sync, XOR checksum, timestamping | `src/mac_uart_bridge.cpp` |
| 3 | Async ERCOT telemetry ingestion (libcurl-multi + simdjson) with SIMD rolling Z-score normalization | `src/ercot_async_client.cpp`, `include/ingest/` |
| 4 | Liquid Time-Constant neural network inference engine on a fused semi-implicit ODE solver | `src/lnn_engine.cpp`, `include/lnn/` |

## Build and test

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

Needs CMake >= 3.20 and a C++20 compiler. The first configure fetches simdjson over the network.

SystemVerilog simulation needs Icarus Verilog (`brew install icarus-verilog`):

```bash
./scripts/run_sim.sh          # all testbenches
./scripts/run_sim.sh lob_pe   # one target
```

## Design notes

`Documentation/ARCHITECTURE_NOTES.md` is an ADR log of the physical limits, protocol
constraints and deliberate trade-offs behind the design.
