#pragma once

#include "ipc/ErcotTelemetry.hpp"
#include "ipc/NormalizedTelemetry.hpp"

#include <array>
#include <cmath>
#include <cstddef>

#if defined(__ARM_NEON)
#  include <arm_neon.h>
#endif

// SIMD feature-normalization stage (roadmap Phase 3): turn each raw ErcotTelemetry signal
// into a rolling Z-score over a fixed window, so the Phase 4 model sees scale-free,
// stationary features. The reducer is vectorized with ARM NEON (the project's target is
// Apple Silicon) and falls back to scalar on other architectures.
//
// Honest scope note (ADR, Documentation/ARCHITECTURE_NOTES.md): the roadmap's "thousands of
// points per microsecond" is aspirational -- the live ERCOT feed delivers a handful of
// samples per *minute*. The NEON kernel below is a correct, genuinely vectorized window
// reducer with real throughput headroom; the binding constraint here is the source rate,
// not the math. The vectorization is exercised for real over the W-sample window per push.
namespace ingest {

// A single feature's rolling window. Capacity W must be a positive multiple of 4 so the
// NEON path consumes the buffer in clean 4-lane (128-bit) loads with no remainder.
//
// Unused slots (before the ring first fills) are held at exactly 0.0f, which contributes
// nothing to either the sum or the sum-of-squares -- so we can always reduce over the full
// W-wide buffer branchlessly and simply divide by the count of *valid* samples. This keeps
// the hot loop free of tail handling.
template <std::size_t W>
class RollingZScore {
    static_assert(W > 0 && (W % 4) == 0, "window must be a positive multiple of 4");

public:
    // Append x, then return its Z-score (x - mean) / stddev over the current window.
    // Returns 0 while the window has <2 samples or stddev collapses to ~0 (constant signal).
    float push(float x) {
        buf_[head_] = x;
        if (++head_ == W) head_ = 0;            // ring wrap (W not required pow2)
        if (valid_ < W) ++valid_;

        float sum = 0.0f, sumsq = 0.0f;
        reduce(sum, sumsq);

        const float n = static_cast<float>(valid_);
        const float mean = sum / n;
        float var = sumsq / n - mean * mean;
        if (var < 0.0f) var = 0.0f;             // guard tiny negative from rounding
        const float sd = std::sqrt(var);
        constexpr float kEps = 1e-9f;
        return (sd > kEps) ? (x - mean) / sd : 0.0f;
    }

private:
    // Sum and sum-of-squares over the whole W-wide buffer (zeros in the unfilled tail are
    // inert). Vectorized with NEON; scalar fallback elsewhere.
    void reduce(float& sum, float& sumsq) const {
#if defined(__ARM_NEON)
        float32x4_t vsum = vdupq_n_f32(0.0f);
        float32x4_t vsq  = vdupq_n_f32(0.0f);
        for (std::size_t i = 0; i < W; i += 4) {
            const float32x4_t v = vld1q_f32(&buf_[i]);
            vsum = vaddq_f32(vsum, v);
            vsq  = vmlaq_f32(vsq, v, v);   // sumsq += v*v, fused
        }
        sum   = vaddvq_f32(vsum);          // horizontal add (aarch64)
        sumsq = vaddvq_f32(vsq);
#else
        for (std::size_t i = 0; i < W; ++i) {
            sum   += buf_[i];
            sumsq += buf_[i] * buf_[i];
        }
#endif
    }

    alignas(16) std::array<float, W> buf_{};  // zero-initialized; 16-B aligned for vld1q
    std::size_t head_  = 0;                    // next write slot
    std::size_t valid_ = 0;                    // # of real samples seen (caps at W)
};

// Normalizes the three continuous ERCOT signals (price, renewable output, reserves) in
// lock-step, emitting one NormalizedTelemetry feature row per raw row. eea_level is a
// discrete escalation flag, not a continuous signal, so it is intentionally not Z-scored.
template <std::size_t W = 128>
class NeonNormalizer {
public:
    ipc::NormalizedTelemetry normalize(const ipc::ErcotTelemetry& raw) {
        ipc::NormalizedTelemetry out{};
        out.timestamp_ns = raw.timestamp_ns;
        out.z_price      = price_.push(static_cast<float>(raw.nodal_price_usd));
        out.z_wind_solar = wind_solar_.push(static_cast<float>(raw.wind_solar_mw));
        out.z_prc        = prc_.push(static_cast<float>(raw.prc_mw));
        return out;
    }

private:
    RollingZScore<W> price_;
    RollingZScore<W> wind_solar_;
    RollingZScore<W> prc_;
};

} // namespace ingest
