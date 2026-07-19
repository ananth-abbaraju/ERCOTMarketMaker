#pragma once

#include "ipc/ErcotTelemetry.hpp"

#include <simdjson.h>

#include <cstdlib>
#include <string>
#include <string_view>

// simdjson On-Demand parsers for the three ERCOT dashboard payloads. Each one mutates only
// the field(s) it owns on a shared ErcotTelemetry "snapshot" and returns false (leaving the
// snapshot untouched) if the body is malformed or missing the expected shape -- so a single
// bad poll can never poison the merged row.
//
// On-Demand is forward-only: fields must be requested in document order and each value fully
// consumed before the next is requested. The accessors below are written to respect that
// (see DevLogs/ERCOT_API.md for the payload layouts), and the whole walk is wrapped in a
// try/catch so any structural surprise degrades to "skip this update" rather than a crash.
//
// These functions are the single source of truth shared by the live client and the offline
// test, so the parse logic is validated without needing the network.
namespace ingest {

// system-wide-prices.json -> nodal_price_usd (latest rtSppData[].hbHubAvg, $/MWh).
inline bool parse_prices(const std::string& body, ipc::ErcotTelemetry& out) {
    try {
        simdjson::ondemand::parser parser;
        simdjson::padded_string json(body);
        simdjson::ondemand::document doc = parser.iterate(json);

        double last_hub = 0.0;
        bool   seen     = false;
        for (auto elem : doc["rtSppData"]) {
            last_hub = elem["hbHubAvg"].get_double();
            seen = true;
        }
        if (!seen) return false;
        out.nodal_price_usd = last_hub;
        return true;
    } catch (const simdjson::simdjson_error&) {
        return false;
    }
}

// daily-prc.json -> prc_mw (latest data[].prc, MW) + eea_level (current_condition, 0..3).
// current_condition precedes data in the document, so it is read first to keep On-Demand
// moving strictly forward.
inline bool parse_prc(const std::string& body, ipc::ErcotTelemetry& out) {
    try {
        simdjson::ondemand::parser parser;
        simdjson::padded_string json(body);
        simdjson::ondemand::document doc = parser.iterate(json);

        const std::uint32_t eea =
            static_cast<std::uint32_t>(doc["current_condition"]["eea_level"].get_int64());

        std::int64_t last_prc = 0;
        bool         seen     = false;
        for (auto elem : doc["data"]) {
            last_prc = elem["prc"].get_int64();
            seen = true;
        }
        if (!seen) return false;
        out.prc_mw    = static_cast<std::uint32_t>(last_prc);
        out.eea_level = eea;
        return true;
    } catch (const simdjson::simdjson_error&) {
        return false;
    }
}

// combine-wind-solar.json -> wind_solar_mw (actualWind + actualSolar of the latest entry
// whose actuals are populated). currentDay.data is an object keyed by epoch strings; future
// hours carry null actuals, so we keep the greatest-epoch entry that has real numbers --
// i.e. the most recent settled hour.
inline bool parse_wind_solar(const std::string& body, ipc::ErcotTelemetry& out) {
    try {
        simdjson::ondemand::parser parser;
        simdjson::padded_string json(body);
        simdjson::ondemand::document doc = parser.iterate(json);

        std::uint64_t best_epoch = 0;
        double        best_sum   = 0.0;
        bool          found      = false;

        for (auto field : doc["currentDay"]["data"].get_object()) {
            // The object key *is* the epoch (ms); read it before touching the value.
            std::string_view key = field.unescaped_key();
            const std::uint64_t epoch =
                std::strtoull(std::string(key).c_str(), nullptr, 10);

            simdjson::ondemand::object o = field.value().get_object();

            // Consume actualWind fully before requesting actualSolar (forward-only).
            double wind;
            {
                simdjson::ondemand::value v = o["actualWind"];
                if (v.is_null()) continue;
                wind = v.get_double();
            }
            double solar;
            {
                simdjson::ondemand::value v = o["actualSolar"];
                if (v.is_null()) continue;
                solar = v.get_double();
            }

            if (epoch >= best_epoch) {
                best_epoch = epoch;
                best_sum   = wind + solar;
                found      = true;
            }
        }

        if (!found) return false;
        out.wind_solar_mw = best_sum;
        return true;
    } catch (const simdjson::simdjson_error&) {
        return false;
    }
}

} // namespace ingest
