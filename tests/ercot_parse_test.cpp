// Offline (no-network) verification of the Phase 3 ingestion logic:
//   1. the simdjson On-Demand parsers extract the right fields from representative ERCOT
//      payloads (modeled on DevLogs/ERCOT_API.md), including the "take the latest entry"
//      and "skip null actuals" rules;
//   2. the NEON rolling-Z-score normalizer agrees with an independent scalar reference,
//      proving the vectorized reduction is correct.
//
// Runs under ctest alongside the pty bridge test; needs no FPGA and no internet.

#include "ingest/ErcotParsers.hpp"
#include "ingest/NeonNormalizer.hpp"
#include "ipc/ErcotTelemetry.hpp"

#include <cmath>
#include <cstdio>
#include <deque>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void check(bool cond, const char* what) {
    if (!cond) { std::printf("  FAIL: %s\n", what); ++g_failures; }
    else       { std::printf("  ok  : %s\n", what); }
}

void check_close(double a, double b, double tol, const char* what) {
    if (std::fabs(a - b) > tol) {
        std::printf("  FAIL: %s (got %.6f, want %.6f)\n", what, a, b);
        ++g_failures;
    } else {
        std::printf("  ok  : %s (%.6f)\n", what, a);
    }
}

// ---- 1. parser tests ----------------------------------------------------------------

// rtSppData carries two intervals; the parser must take the LAST hbHubAvg (12.13), and
// must ignore damSppData entirely.
const char* kPrices = R"({
  "lastUpdated": "2026-06-28 12:02:00-0500",
  "rtSppData": [
    { "intervalEnding": "11:55", "hbBusAvg": 15.0, "hbHubAvg": 11.00, "lzHouston": 25.0 },
    { "intervalEnding": "12:00", "hbBusAvg": 15.75, "hbHubAvg": 12.13, "lzHouston": 25.21 }
  ],
  "damSppData": [
    { "hourEnding": 24, "hbHubAvg": 25.04 }
  ]
})";

// current_condition.eea_level (0) precedes data; data carries two prc points and the parser
// must take the LAST (10885).
const char* kPrc = R"({
  "lastUpdated": "2026-06-28 12:12:13-0500",
  "current_condition": {
    "condition_note": "There is enough power for current demand.",
    "eea_level": 0, "energy_level_value": 20, "state": "normal",
    "prc_value": "18,983", "index": 4393, "datetime": 1782666733
  },
  "data": [
    { "timestamp": "2026-06-28 00:00:05-0500", "epoch": 1782622805000, "prc": 10914 },
    { "timestamp": "2026-06-28 00:00:13-0500", "epoch": 1782622813000, "prc": 10885 }
  ]
})";

// Two settled hours with populated actuals plus a future hour with null actuals. The parser
// must pick the greatest-epoch entry that has real numbers (1782703600000 -> 13000 + 3500),
// not the later null one and not the earlier settled one.
const char* kWindSolar = R"({
  "lastUpdated": "2026-06-28 11:55:27-0500",
  "currentDay": {
    "date": "2026-06-28 03:00:00-0500",
    "data": {
      "1782700000000": { "hourEnding": 22, "actualWind": 12000, "epoch": 1782700000000, "actualSolar": 3000 },
      "1782703600000": { "hourEnding": 23, "actualWind": 13000, "epoch": 1782703600000, "actualSolar": 3500 },
      "1782709200000": { "hourEnding": 24, "actualWind": null,  "epoch": 1782709200000, "actualSolar": null }
    }
  },
  "nextDay": { "date": "2026-06-29 03:00:00-0500", "data": {} }
})";

void test_parsers() {
    std::printf("[parsers]\n");
    ipc::ErcotTelemetry t{};

    check(ingest::parse_prices(kPrices, t), "parse_prices returns true");
    check_close(t.nodal_price_usd, 12.13, 1e-9, "nodal_price_usd = latest rtSppData hbHubAvg");

    check(ingest::parse_prc(kPrc, t), "parse_prc returns true");
    check(t.prc_mw == 10885u, "prc_mw = latest data[].prc");
    check(t.eea_level == 0u, "eea_level = current_condition.eea_level");

    check(ingest::parse_wind_solar(kWindSolar, t), "parse_wind_solar returns true");
    check_close(t.wind_solar_mw, 16500.0, 1e-9,
                "wind_solar_mw = latest non-null actualWind + actualSolar");

    // Malformed / empty payloads must fail cleanly (false), not crash.
    ipc::ErcotTelemetry t2{};
    check(!ingest::parse_prices("{ this is not json", t2), "parse_prices rejects garbage");
    check(!ingest::parse_prices(R"({"rtSppData":[]})", t2), "parse_prices rejects empty array");
}

// ---- 2. NEON vs scalar normalizer ---------------------------------------------------

// Independent reference: population mean/std over the last min(count, W) samples, exactly
// the sliding window the normalizer maintains.
template <std::size_t W>
float scalar_zscore(std::deque<float>& window, float x) {
    window.push_back(x);
    if (window.size() > W) window.pop_front();
    double sum = 0.0, sumsq = 0.0;
    for (float v : window) { sum += v; sumsq += double(v) * v; }
    const double n = double(window.size());
    const double mean = sum / n;
    double var = sumsq / n - mean * mean;
    if (var < 0.0) var = 0.0;
    const double sd = std::sqrt(var);
    return (sd > 1e-9) ? float((x - mean) / sd) : 0.0f;
}

void test_normalizer() {
    std::printf("[normalizer] NEON vs scalar over a sliding window\n");
    constexpr std::size_t W = 8;
    ingest::RollingZScore<W> neon;
    std::deque<float> ref;

    // A non-trivial sequence longer than the window so the ring wraps and we exercise the
    // steady-state W-wide reduction, not just the fill phase.
    const std::vector<float> seq = {
        10.f, 12.f, 9.f, 14.f, 11.f, 13.f, 8.f, 15.f,
        20.f, 5.f, 18.f, 7.f, 22.f, 3.f, 25.f, 1.f, 30.f };

    int i = 0;
    for (float x : seq) {
        const float z_neon   = neon.push(x);
        const float z_scalar = scalar_zscore<W>(ref, x);
        char label[64];
        std::snprintf(label, sizeof(label), "z[%d] (x=%.0f) NEON==scalar", i++, x);
        check_close(z_neon, z_scalar, 1e-3, label);
    }
}

} // namespace

int main() {
    test_parsers();
    test_normalizer();

    if (g_failures == 0) {
        std::printf("\nALL PASSED\n");
        return 0;
    }
    std::printf("\n%d CHECK(S) FAILED\n", g_failures);
    return 1;
}
