#pragma once

#include "ipc/SPSCQueue.hpp"
#include "ipc/HandshakeRegion.hpp"
#include "ipc/ErcotTelemetry.hpp"
#include "ipc/NormalizedTelemetry.hpp"

#include <cstddef>

// Single source of truth for the ERCOT telemetry channels: the shared-memory queue
// types and segment names. The async ingestion client (producer/creator), the live
// consumer, the Phase 1 benchmark producer/consumer, and the offline tests all include
// this so the two sides of each queue can never drift.
//
// Two parallel channels flow out of the ingestion engine:
//   RAW  (/ercot_queue_shm) : merged ErcotTelemetry rows straight from the endpoints.
//   NORM (/ercot_norm_shm)  : NEON-normalized NormalizedTelemetry feature rows.
namespace ipc {

// Capacity MUST be a power of two (see SPSCQueue static_assert). Shared by both channels.
inline constexpr std::size_t ERCOT_QUEUE_CAPACITY = 1024 * 64;

inline constexpr const char* ERCOT_SHM_NAME      = "/ercot_queue_shm";
inline constexpr const char* ERCOT_NORM_SHM_NAME = "/ercot_norm_shm";

using ErcotQueue  = SPSCQueue<ErcotTelemetry, ERCOT_QUEUE_CAPACITY>;
using ErcotRegion = HandshakeRegion<ErcotQueue>;

using NormQueue  = SPSCQueue<NormalizedTelemetry, ERCOT_QUEUE_CAPACITY>;
using NormRegion = HandshakeRegion<NormQueue>;

} // namespace ipc
