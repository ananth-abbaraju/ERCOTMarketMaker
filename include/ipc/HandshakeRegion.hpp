#pragma once

#include <atomic>
#include <cstdint>

namespace ipc {

// Wraps an SPSC queue (or any trivially-constructible payload) in shared memory
// alongside a pair of atomic flags used for a deterministic startup handshake.
//
// This replaces the old "producer sleeps N seconds and hopes the consumer attached"
// approach. With these flags the two processes can be launched in EITHER order, and
// the producer only begins streaming once the consumer has attached and signalled
// readiness -- so no telemetry is produced into the void before anyone is listening.
//
// Protocol:
//   Producer (creator):  placement-new region -> store producer_ready=1 (release)
//                        -> spin until consumer_ready==1 (acquire) -> stream.
//   Consumer (attacher): wait until producer_ready==1 (acquire)
//                        -> store consumer_ready=1 (release) -> drain.
//
// The flags live on their own cache lines (one written by each side) to avoid the
// handshake introducing false sharing with the payload or with each other.
template<typename Payload>
struct HandshakeRegion {
    alignas(64) std::atomic<uint32_t> producer_ready{0};
    alignas(64) std::atomic<uint32_t> consumer_ready{0};
    alignas(64) Payload payload;
};

} // namespace ipc
