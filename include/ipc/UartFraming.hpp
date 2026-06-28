#pragma once

#include "ipc/MarketDataChannel.hpp"

#include <array>
#include <cstdint>
#include <cstddef>

// Big-endian (network order) wire helpers + frame builders shared by both ends of the
// UART link. The FPGA RTL parses/produces these exact byte layouts; keeping the host
// encode/decode here means the bridge and its loopback test can never disagree on the
// format. (The bridge builds MDP frames + parses TOB frames; the fake-FPGA test does the
// inverse, so both directions are exercised against the same code.)
namespace ipc::wire {

inline void put_be16(std::uint8_t* p, std::uint16_t v) {
    p[0] = std::uint8_t(v >> 8); p[1] = std::uint8_t(v);
}
inline void put_be32(std::uint8_t* p, std::uint32_t v) {
    p[0] = std::uint8_t(v >> 24); p[1] = std::uint8_t(v >> 16);
    p[2] = std::uint8_t(v >> 8);  p[3] = std::uint8_t(v);
}
inline void put_be64(std::uint8_t* p, std::uint64_t v) {
    for (int i = 0; i < 8; ++i) p[i] = std::uint8_t(v >> (8 * (7 - i)));
}
inline std::uint32_t get_be32(const std::uint8_t* p) {
    return (std::uint32_t(p[0]) << 24) | (std::uint32_t(p[1]) << 16) |
           (std::uint32_t(p[2]) << 8)  |  std::uint32_t(p[3]);
}
inline std::uint64_t get_be64(const std::uint8_t* p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
    return v;
}

// XOR checksum over the price+vol bytes of a TOB frame (frame[1..12]).
inline std::uint8_t tob_checksum(const std::uint8_t* frame) {
    std::uint8_t c = 0;
    for (std::size_t i = 1; i <= 12; ++i) c ^= frame[i];
    return c;
}

// Build a 32-byte inbound frame: 20-byte header (payload_len=12) + price(8 BE) + vol(4 BE).
inline std::array<std::uint8_t, MDP_FRAME_LEN>
build_mdp_frame(std::uint16_t msg_type, std::int64_t price, std::uint32_t vol,
                std::uint32_t seq = 1, std::uint32_t instrument = 42) {
    std::array<std::uint8_t, MDP_FRAME_LEN> f{};
    put_be16(&f[0],  msg_type);
    put_be32(&f[2],  seq);
    put_be32(&f[6],  instrument);
    // f[10..17] timestamp left zero
    put_be16(&f[18], std::uint16_t(MDP_PAYLOAD_LEN));
    put_be64(&f[20], std::uint64_t(price));
    put_be32(&f[28], vol);
    return f;
}

// Build a 14-byte top-of-book frame: [0xAA][price 8 BE][vol 4 BE][xor checksum].
inline std::array<std::uint8_t, TOB_FRAME_LEN>
build_tob_frame(std::int64_t price, std::uint32_t vol) {
    std::array<std::uint8_t, TOB_FRAME_LEN> f{};
    f[0] = TOB_SYNC;
    put_be64(&f[1], std::uint64_t(price));
    put_be32(&f[9], vol);
    f[13] = tob_checksum(f.data());
    return f;
}

} // namespace ipc::wire
