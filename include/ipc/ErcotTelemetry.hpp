#pragma once

#include <cstdint>

namespace ipc {

// Cache-line aligned struct to prevent false sharing when transferred across logical cores.
// Hardcoded to 64 bytes to perfectly fit modern L1 cache line sizes.
struct alignas(64) ErcotTelemetry {
    uint64_t timestamp_ns;          // 8 bytes
    double grid_frequency_hz;       // 8 bytes
    double nodal_price_usd;         // 8 bytes
    double wind_speed_mph;          // 8 bytes
    uint32_t station_id;            // 4 bytes
    
    // The compiler will automatically pad this to exactly 64 bytes 
    // to satisfy the alignas(64) requirement.
};

} // namespace ipc
