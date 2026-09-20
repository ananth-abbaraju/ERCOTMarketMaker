# ERCOT Market Maker

A hardware/software co-designed HFT-style engine, built for exploration. Simulated CME MDP 3.0
market data comes in through an FPGA fast path, live ERCOT (Texas grid) telemetry through an
async C++ client, and lock-free shared-memory IPC wires the stages together. The signal comes
from a continuous-time Liquid Neural Network, built on a custom fused semi-implicit ODE
solver, which emits Buy/Sell/Hold.

## Architecture

Separate processes, wired by single-producer/single-consumer lock-free queues in POSIX shared memory.

| Phase | What | Where |
|-------|------|-------|
| 1 | Lock-free SPSC ring buffer over POSIX shared memory, 64-byte cache-line aligned | `include/ipc/` |
| 2 | SystemVerilog MDP 3.0 / SBE decoder feeding a systolic-array limit order book with O(1) top-of-book reads | `hardware/` |
| 2.5 | Host-side UART bridge: frame sync, XOR checksum, timestamping | `src/mac_uart_bridge.cpp` |
| 3 | Async ERCOT telemetry ingestion (libcurl-multi + simdjson) with SIMD rolling Z-score normalization | `src/ercot_async_client.cpp`, `include/ingest/` |
| 4 | Liquid Time-Constant neural network inference engine | `src/lnn_engine.cpp`, `include/lnn/` |

## Build and test

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

Needs CMake >= 3.20 and a C++20 compiler. The first configure fetches simdjson over the network.
