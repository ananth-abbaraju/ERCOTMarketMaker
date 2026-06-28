# Architecture Notes — Limitations, Quirks & Engineering Realities

**Document type:** Architecture Decision Record (ADR) / System Limitations & Trade-offs

---

## Purpose

This document is not a tutorial on how the system works nor feature list. It is a
record of the **physical limitations, protocol constraints, platform quirks, and
deliberate trade-offs** that shaped the design — the "why it is built this way, and what
it costs" that is normally lost between commits.

Every entry below documents a *reality I did not get to choose* (a silicon behaviour, a
wire protocol, a host OS policy, a baud-rate ceiling) followed by the decision taken to
work within it and the residual trade-off I accepted. Entries are ordered chronologically
by development phase. Where a decision is a known compromise, it is
called out explicitly so it can be revisited.

---

## Phase 1 — Zero-Copy IPC & Software Ingress

### ADR-001 — Apple Silicon defeats strict POSIX core pinning
**Reality.** The low-latency playbook assumes a thread can be hard-bound to an isolated
core (`sched_setaffinity` / `pthread_setaffinity_np`) to eliminate migration and
cross-core scheduler jitter. Apple Silicon (and macOS broadly) exposes **no public CPU
affinity API**. The closest primitive, the Mach `THREAD_AFFINITY_POLICY`, is only an
*L2-cache-sharing hint* and is **documented as ignored on the Apple SoCs**. The kernel
alone decides placement across the P-core / E-core asymmetric topology.

**Decision.** We treat pinning as *best-effort advisory*, not a guarantee. Each hot thread
sets the Mach affinity tag (harmless where ignored) **and** raises its Quality-of-Service
class to `QOS_CLASS_USER_INTERACTIVE`, which is the only lever that reliably biases the
scheduler toward keeping work on the performance cores. The Linux path retains true
`pthread_setaffinity_np` under the same helper (`pin_thread()` in
`src/mac_uart_bridge.cpp`).

**Trade-off.** On macOS we cannot claim deterministic core residency or guarantee freedom
from E-core demotion; reported tail latencies include residual scheduler jitter. This is
acceptable for a research/verification target and is the strongest reason the production
critical path ultimately belongs in hardware, not on the host CPU.

### ADR-002 — Cache-line bouncing between the ingress and inference cores
**Reality.** An SPSC ring shared by a producer core and a consumer core suffers **false
sharing**: if the head index, the tail index, and the payload land on the same 64-byte
cache line, every producer write invalidates the consumer's copy of that line (and vice
versa), forcing MESI coherence traffic on what should be an independent read.

**Decision.** Every independently-written field is isolated onto its own cache line with
`alignas(64)` — `head_` and `tail_` in `include/ipc/SPSCQueue.hpp`, and the
`producer_ready` / `consumer_ready` flags plus payload in
`include/ipc/HandshakeRegion.hpp`. Payload structs (`ErcotTelemetry`, `MarketDataTick`)
are themselves 64-byte aligned so each element occupies a clean line.

**Trade-off.** We pay memory: indices and flags are padded out to a full line, and small
payloads are rounded up to 64 bytes. In exchange the enqueue→dequeue hop is dominated by a
single coherence transfer (measured **min ≈ 83 ns** core-to-core) rather than by repeated
invalidations.

### ADR-003 — Power-of-two ring capacity to avoid a hot-path division
**Reality.** Wrapping a ring index with `% Capacity` compiles to an integer division —
tens of cycles on the critical path, every push and pop.

**Decision.** Capacity is constrained to a power of two via `static_assert`, and wrap is a
single-cycle bitmask (`& (Capacity - 1)`). See `include/ipc/SPSCQueue.hpp`.

**Trade-off.** Capacities are restricted to powers of two — a non-constraint in practice.

### ADR-004 — SIGBUS-safe shared-memory attach (the zero-length `mmap` trap)
**Reality.** A POSIX shared segment is created in two non-atomic steps: `shm_open`
(`O_CREAT`) then `ftruncate` to size it. A consumer that maps the object in the window
*after* it exists but *before* it is sized maps a zero-length region; the first byte
touched raises **`SIGBUS`** and kills the process. Launch order is not guaranteed.

**Decision.** The attacher in `include/ipc/SharedMemoryManager.hpp` polls until the segment
both **exists** (`shm_open` retried past `ENOENT`) **and is fully sized**
(`fstat().st_size >= sizeof(T)`) before calling `mmap`, bounded by a 5-second deadline.

**Trade-off.** A bounded startup busy-wait (200 µs back-off) in exchange for launch-order
independence and immunity to the SIGBUS race. This is strictly startup, off the hot path.

### ADR-005 — Startup handshake replaces the "sleep and hope" producer
**Reality.** An earlier design had the producer sleep a fixed 3 seconds expecting the
consumer to attach. This both wastes time and silently streams data into the void if the
consumer is late.

**Decision.** A two-flag release/acquire handshake (`producer_ready` → `consumer_ready`)
makes the two processes launch-order independent; the producer streams only once a
consumer has acknowledged attach.

**Trade-off.** None of consequence. Documented here because it is a reality the
measurement methodology depends on.

### ADR-006 — Honest latency labelling (queue residence ≠ transport cost)
**Reality.** The producer bursts ticks far faster than a single consumer drains them, so
the ring runs full and most ticks sit *queued*. A naive "average latency" therefore
measures **queue-residence time under load**, not the core-to-core transport cost, and
overstates the transport figure by orders of magnitude.

**Decision.** The consumer reports **Min / Avg / Max separately** and labels them: Min
(seen while the ring is shallow) is the honest approximation of the raw enqueue→dequeue
hop; Avg explicitly carries the "incl. queue residence under load" qualifier.

**Trade-off.** None — this is a reporting-integrity decision. It exists so the ~83 ns
figure is never confused with sustained-throughput latency.

---

## Phase 2 — Hardware Systolic Array (Artix-7 Limit Order Book)

### ADR-007 — The SBE payload reality: the MDP 3.0 header carries no price/volume
**Reality.** CME's **MDP 3.0 / Simple Binary Encoding** separates the *message header*
from the *message body*. The 20-byte binary header
(`msg_type, seq_num, instrument_id, timestamp, payload_len`) contains **no price and no
quantity** — those live in the SBE repeating group that follows. A single-stage "parse the
header and you have the order" assumption is physically impossible against the real
protocol.

**Decision.** A **two-stage streaming decoder**:
`mdp3_parser.sv` (header) → `mdp3_payload_decoder.sv` (SBE body), chained on one byte
stream. The header parser extracts `payload_len` and `msg_type`; the payload decoder then
walks exactly `payload_len` bytes and lifts the 64-bit price and 32-bit volume from their
fixed offsets, gated on `msg_type == MDIncrementalRefreshBook`.

**Sub-reality — the parser must be *gated*, not just chained.** `mdp3_parser` is stateless
with respect to payloads: it blindly frames *every* 20 bytes as a new header. Naively
feeding it the continuous stream would cause it to consume the 12 payload bytes as a
phantom header and **mis-frame every subsequent message**. The payload decoder therefore
owns the frame phase and drives the parser's `in_valid` enable — holding the parser idle
for the duration of the payload window. This is safe because `uart_rx` delivers bytes as
single-cycle strobes spaced a full UART frame apart, so the parser's registered
`out_valid` lands in the inter-byte gap with no simultaneity hazard.

**Trade-off.** Tighter coupling between the two modules (the decoder gates the parser)
in exchange for correct, indefinitely-reframable back-to-back parsing.

### ADR-008 — Memory-width safety: provably no overflow from the SBE int64 mantissa
**Reality.** CME SBE prices are an **8-byte signed integer mantissa** (e.g. `PRICE9` =
display price × 10⁹). A 32-bit price datapath — the LOB's original width — cannot represent
a realistic mantissa; it would silently truncate and corrupt book ordering.

**Decision.** The price datapath is **64 bits end-to-end** by construction: the decoder
emits `price[63:0]`, and `lob_array` / `lob_pe` are instantiated with `PRICE_W = 64`.
Because the payload field, the decoder output, and the array storage are all exactly 64
bits, the mapping is width-exact and **overflow is impossible by elaboration**, not by
runtime check. Volume remains 32-bit (CME quantities are int32).

**Trade-off.** Wider comparators and storage per processing element (64-bit vs 32-bit
price compare) — a modest area cost on the Artix-7 fabric, paid once, for correctness.

### ADR-009 — Overwrite (not delta) book semantics, per MDP 3.0
**Reality.** An MDP 3.0 Incremental Refresh communicates the **absolute resting quantity**
at a price level, not a delta against prior state. Applying updates as increments would
desynchronise the book on any dropped or reordered message.

**Decision.** A price-level match is handled as an **overwrite** (`vol <= in_vol`) in
`lob_pe.sv`, and a `vol == 0` update is a **delete**. This makes each message
self-contained: the book is recoverable from the latest update for a level regardless of
history.

**Trade-off.** None relative to the protocol — this *is* the protocol's contract. Recorded
because it dictates the PE's update logic.

### ADR-010 — The delete-collapse token: O(1) gap-healing without ghost liquidity
**Reality.** In a sorted systolic book, an insert ripples *rightward* (compare-and-shove).
A **delete is the hard direction**: removing an interior level must pull every
worse-priced level left by one to keep the book compact. The naive "flag the slot empty,
pull from the right next cycle" approach has a fatal flaw — a PE that copies its right
neighbour's value leaves that neighbour **still holding the same value, with no way to know
it must now clear itself**. The result is either *duplicated liquidity* (the same order at
two adjacent levels) or a *one-cycle ghost hole* that a concurrent read can observe.

**Decision.** Deletion is driven by an explicit **rightward-rippling collapse control
token** travelling on a dedicated channel, against the leftward data-pull channel
(`in_right → out_left`). On a delete-match a PE pulls its right neighbour's contents into
itself *and emits the collapse token rightward*; each PE that receives the token does the
same and forwards it, until the wave reaches an empty cell where it dies. Every cell is
thus explicitly told to pull-and-shift exactly once — no cell is left holding a stale
duplicate, and there is no observable hole. An additional guard (`evict` requires
`in_left_vol != 0`) ensures a **delete-miss cannot phantom-insert** an empty order.
Top-of-book remains readable in **O(1)** (constant) cycles regardless of book depth.

**Trade-off.** A second control channel and token logic per PE. This is the core
architectural insight of the array and the reason it is correct under deletion.

### ADR-011 — One operation in flight (no pipeline-hazard arbitration)
**Reality.** A fully pipelined array could have an insert wave and a collapse wave in
flight simultaneously; where they meet, the data and control channels race and require
hazard arbitration to resolve ordering.

**Decision.** The current array processes **one operation at a time** — an operation is
allowed to fully ripple/settle before the next is admitted. Hazard arbitration for
overlapping waves is explicitly **out of scope**.

**Trade-off.** Throughput is bounded by the ripple-settle interval rather than one
operation per clock. Given the UART ingress ceiling (ADR-012) this is *not* the binding
constraint — the link delivers operations far slower than the array can settle them — so
the simpler, provably-correct single-op design is the right call until the transport is
upgraded.

---

## Phase 2.5 — The Hardware-in-the-Loop Bridge

### ADR-012 — The UART physics limit: the FT2232 link is the binding bottleneck
**Reality.** The Basys 3's only host link is its onboard **FTDI FT2232 USB-UART** bridge.
At **115200 baud, 8N1**, each byte costs 10 bits on the wire (1 start + 8 data + 1 stop),
so the channel delivers a hard **11,520 bytes/second** — a fixed physical ceiling,
independent of how fast the O(1) array or the host can run.

Per-direction frame rates at our actual frame sizes:

| Direction | Frame | Size | Max rate |
|-----------|-------|------|----------|
| Ingress (Mac → FPGA) | MDP 3.0 header + SBE payload | 32 B | **≈ 360 frames/s** |
| Egress (FPGA → Mac) | top-of-book update | 14 B | **≈ 820 frames/s** |

The **binding constraint is the 32-byte ingress frame at ~360 frames/s**. (A frequently
quoted "~575 frames/s" corresponds to a hypothetical 20-byte frame, `11520 / 20`; our
ingress frame is larger because it carries the full 20-byte MDP header *plus* the 12-byte
SBE payload.)

**Decision.** Accept the ceiling. UART is retained purely as a **functional-verification
transport** — it is fast enough to prove the parser, the sorted-insert, and the O(1)
delete-heal end-to-end, which is its entire job at this stage. The roadmap explicitly
**defers** the high-speed transport (Ethernet PHY / USB 3.0 FIFO over PMOD) as a separate
step.

**Trade-off.** ~360 frames/s is *functionally* sufficient but *nowhere near* HFT line
rate. No throughput or latency claim derived over this link reflects the array's true
capability — the link, not the silicon, sets the number. This is the single most important
limitation to keep in mind when reading any Phase 2.5 measurement.

### ADR-013 — Host-side timestamping (the FPGA has no PTP-synced clock)
**Reality.** True exchange-grade latency attribution requires a **hardware timestamp at the
point of wire arrival**, ideally PTP/IEEE-1588 synchronised. The Basys 3 has **no
PTP-disciplined hardware clock**; the FPGA cannot stamp events against a host-comparable
time base.

**Decision.** `MarketDataTick.timestamp_ns` is stamped by the **host ingress thread** at
the instant a full 14-byte frame is reassembled off the serial line
(`now_ns()` in `src/mac_uart_bridge.cpp`).

**Trade-off.** The stamp measures **wire-arrival → queue** on the host and therefore
*includes* UART serialisation delay and host scheduling jitter, and *excludes* the FPGA's
internal compute time. It is an honest ingress reference point, not a hardware
exchange-to-decision timestamp, and must not be presented as the latter. Closing this gap
requires a disciplined hardware clock on the FPGA — a prerequisite that travels with the
deferred high-speed-transport work.

### ADR-014 — The egress serial protocol: sync byte + XOR checksum framing
**Reality.** A raw asynchronous UART byte stream has **no inherent message framing**. A
receiver that drops or gains a single byte (line glitch, buffer overrun, mid-stream
attach) loses alignment permanently with no way to recover, and silently mis-interprets
every subsequent frame.

**Decision.** Top-of-book updates use a fixed **14-byte egress frame**:

```
[0]      0xAA            sync byte
[1..8]   price           int64, big-endian
[9..12]  volume          uint32, big-endian
[13]     checksum        XOR of bytes [1..12]
```

The host ingress (`tob_serializer.sv` ⇄ the bridge's RX loop) **hunts the `0xAA` sync byte**
to (re)establish alignment, then validates the **XOR checksum** before admitting the frame;
a mismatch is dropped and the receiver resynchronises from the next sync byte. The frame is
emitted **only when the best level changes** (not on every message), conserving the scarce
UART bandwidth of ADR-012.

**Trade-off — coalescing under burst.** The serializer transmits the *current* top-of-book
when the TX line is free, not a queue of every intermediate state. If the best level
changes faster than a 14-byte frame can drain (≈ ADR-012), intermediate states are
**coalesced** — the host sees the latest top-of-book, not every transition. For a
top-of-book feed this is acceptable and intentional; a full per-event audit trail would
require a different (and far more bandwidth-hungry) egress contract. The 0xAA sync byte
also imposes the usual caveat that a genuine `0xAA` *price* byte is disambiguated only by
the checksum + fixed frame length, not by byte-stuffing.

### ADR-015 — `-std=c++20` hides the BSD/Darwin APIs the bridge needs
**Reality.** The project builds in **strict-standard mode** (`CMAKE_CXX_EXTENSIONS OFF` →
`-std=c++20`), which defines `__STRICT_ANSI__`. On macOS this **hides the BSD/Darwin
extensions** the serial bridge depends on — `cfmakeraw`, `posix_openpt`, and the Mach
thread-policy / QoS calls — producing implicit-declaration failures.

**Decision.** Re-expose them narrowly: `add_compile_definitions(_DARWIN_C_SOURCE)` guarded
by `if (APPLE)` in `CMakeLists.txt`, leaving strict standard conformance otherwise intact.

**Trade-off.** A platform-conditional build definition, isolated to Apple, in exchange for
keeping the rest of the codebase on a strict, portable language standard.

### ADR-016 — `pty`-based verification without hardware
**Reality.** Continuous verification of the host bridge cannot depend on a physical Basys 3
being plugged in (no board, no PTP, no FTDI in CI).

**Decision.** `tests/uart_bridge_pty_test.cpp` opens a **pseudo-terminal** as a stand-in
"serial cable": it spawns the *real* `mac_uart_bridge` against the pty slave, plays a
software FPGA twin on the master side (parsing the bridge's MDP frames, running a trivial
software book, returning 14-byte top-of-book frames), and drains the SPSC queue to assert
the round-trip. This exercises the genuine feeder serialisation, the zero-yield ingress
sync-hunt + checksum path, and the lock-free push — no hardware required.

**Trade-off.** A pty faithfully models the *byte semantics* of the link but **not its
physics**: it has no 115200-baud rate limit, no line noise, and no FTDI buffering. It
validates protocol correctness, not timing behaviour. Timing claims still require the real
board (subject to ADR-012 / ADR-013).

---

## Cross-cutting summary

| Constraint we did not choose | Where it bites | Our accommodation |
|------------------------------|----------------|-------------------|
| No CPU affinity on Apple Silicon | Host hot threads | QoS hint, best-effort (ADR-001) |
| 64-byte coherence granularity | SPSC ring | Per-line `alignas(64)` (ADR-002) |
| Non-atomic shm create+size | Startup | Poll-until-sized attach (ADR-004) |
| MDP 3.0 header has no price/vol | FPGA parse | Two-stage gated decoder (ADR-007) |
| SBE int64 price mantissa | LOB width | 64-bit datapath by elaboration (ADR-008) |
| Sorted-book deletion correctness | Systolic array | Rightward collapse token (ADR-010) |
| FT2232 @ 115200 baud | Transport | Accept ~360 fps; defer fast link (ADR-012) |
| No PTP clock on Basys 3 | Timestamping | Host wire-arrival stamp (ADR-013) |
| Unframed async UART | Egress | 0xAA sync + XOR checksum (ADR-014) |

**The throughline:** the host CPU and the UART link — not the O(1) hardware array — are the
binding constraints today. Every deferred item on the roadmap (kernel-bypass transport,
high-speed PHY, a disciplined hardware clock) targets one of the realities recorded here.
