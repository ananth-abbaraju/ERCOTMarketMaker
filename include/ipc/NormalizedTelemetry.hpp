#pragma once

#include <cstdint>

namespace ipc {

// One inference-ready feature row: the rolling Z-scores of the raw ErcotTelemetry signals,
// produced by the NEON normalization stage (include/ingest/NeonNormalizer.hpp) and flushed
// into a dedicated lock-free buffer (/ercot_norm_shm) for the Phase 4 inference engine.
//
// Cache-line aligned (64 B), same false-sharing discipline as ErcotTelemetry: each row
// occupies its own L1 line as it crosses the producer/consumer cores in the SPSC ring.
//
// timestamp_ns is copied straight from the raw row that produced these features, so a
// consumer can join the normalized stream back to the raw telemetry it was derived from.
// Z-scores are floats: NEON processes 4 lanes per instruction, and single precision is
// ample for normalized features feeding the model.
struct alignas(64) NormalizedTelemetry {
    uint64_t timestamp_ns;   // 8 bytes - inherited from the source raw row
    float    z_price;        // 4 bytes - rolling Z-score of nodal_price_usd
    float    z_wind_solar;   // 4 bytes - rolling Z-score of wind_solar_mw
    float    z_prc;          // 4 bytes - rolling Z-score of prc_mw

    // Padded by the compiler to exactly 64 bytes to satisfy alignas(64).
};

} // namespace ipc
