#pragma once

#include "ipc/SPSCQueue.hpp"
#include "ipc/HandshakeRegion.hpp"
#include "ipc/MarketDataTick.hpp"

#include <cstddef>
#include <cstdint>

// Single source of truth for the FPGA-bridge market-data channel: the shared-memory
// queue type/name and the UART wire-framing constants. The bridge, the standalone
// consumer, and the pty test all include this so the two sides can never drift.
namespace ipc {

// Dedicated MD queue (kept entirely separate from the Phase 1 ErcotTelemetry queue).
inline constexpr std::size_t MD_QUEUE_CAPACITY = 1024 * 64;  // power of two (SPSC req.)
inline constexpr const char* MD_SHM_NAME       = "/ercot_md_shm";

using MdQueue  = SPSCQueue<MarketDataTick, MD_QUEUE_CAPACITY>;
using MdRegion = HandshakeRegion<MdQueue>;

// ---- Inbound frame (Mac -> FPGA): 20-byte MDP 3.0 header + 12-byte SBE payload ----
inline constexpr std::size_t MDP_HEADER_LEN = 20;
inline constexpr std::size_t MDP_PAYLOAD_LEN = 12;     // price(8) + vol(4)
inline constexpr std::size_t MDP_FRAME_LEN   = MDP_HEADER_LEN + MDP_PAYLOAD_LEN;  // 32
inline constexpr std::uint16_t MSG_INCREMENTAL = 46;   // CME MDIncrementalRefreshBook id

// ---- Outbound top-of-book frame (FPGA -> Mac): [0xAA][price 8 BE][vol 4 BE][xor] ----
inline constexpr std::uint8_t  TOB_SYNC      = 0xAA;
inline constexpr std::size_t   TOB_FRAME_LEN = 14;

} // namespace ipc
