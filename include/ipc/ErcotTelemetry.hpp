#pragma once

#include <cstdint>

namespace ipc {

// One row of live ERCOT grid telemetry, merged from the public dashboard endpoints.
//
// Cache-line aligned (64 B) to prevent false sharing when the row crosses cores in the
// SPSC ring (same discipline as MarketDataTick) -- 32 bytes are used, padded to one line.
//
// Field mapping (see DevLogs/ERCOT_API.md):
//   nodal_price_usd  <- system-wide-prices.json : latest rtSppData[].hbHubAvg ($/MWh)
//   wind_solar_mw    <- combine-wind-solar.json : latest actualWind + actualSolar (MW)
//   prc_mw           <- daily-prc.json          : latest data[].prc  (reserves, MW)
//   eea_level        <- daily-prc.json          : current_condition.eea_level (0..3)
//
// We deliberately track PRC (Physical Responsive Capability, i.e. operating reserves)
// rather than grid frequency: the daily-prc feed carries reserves, not frequency, and
// reserves drying up is a *leading* indicator of price volatility -- we predict stress
// instead of waiting for the grid to actually fail. eea_level is the discrete escalation
// of that same stress (0 = normal ... 3 = emergency).
struct alignas(64) ErcotTelemetry {
    uint64_t timestamp_ns;     // 8 bytes - host ingest stamp (now_ns at push)
    double   nodal_price_usd;  // 8 bytes - system hub average real-time price ($/MWh)
    double   wind_solar_mw;    // 8 bytes - actual renewable generation (MW)
    uint32_t prc_mw;           // 4 bytes - physical responsive capability / reserves (MW)
    uint32_t eea_level;        // 4 bytes - energy emergency alert level (0..3)

    // Padded by the compiler to exactly 64 bytes to satisfy alignas(64).
};

} // namespace ipc
