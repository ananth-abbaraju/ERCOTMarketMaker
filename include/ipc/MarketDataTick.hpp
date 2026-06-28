#pragma once

#include <cstdint>

namespace ipc {

// One decoded top-of-book update flowing FPGA -> Mac. Cache-line aligned (64 B) to keep
// each tick on its own L1 line and avoid false sharing as it crosses cores in the SPSC
// ring -- same discipline as ErcotTelemetry.
//
// price is the raw CME SBE mantissa (e.g. PRICE9 = display price * 1e9), kept as an
// int64 so no precision is lost on the host. volume == 0 denotes an emptied level.
// timestamp_ns is stamped by the ingress thread the instant a full frame is reassembled
// off the wire -- it marks wire-arrival, the reference point for wire->queue latency.
struct alignas(64) MarketDataTick {
    uint64_t timestamp_ns;   // 8 bytes - host ingress timestamp
    int64_t  price;          // 8 bytes - SBE mantissa
    uint32_t volume;         // 4 bytes - 0 => level removed

    // Padded by the compiler to a full 64-byte cache line.
};

} // namespace ipc
