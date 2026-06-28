// md_consumer -- attaches to the FPGA-bridge market-data queue (/ercot_md_shm) and drains
// top-of-book updates, printing each MarketDataTick plus the wire->queue latency. This is
// the downstream user-space reader for live hardware-in-the-loop runs (pair it with
// mac_uart_bridge). It creates/destroys nothing; the bridge owns the segment.

#include "ipc/SharedMemoryManager.hpp"
#include "ipc/MarketDataChannel.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <iostream>

namespace {
std::atomic<bool> g_running{true};
void on_signal(int) { g_running.store(false, std::memory_order_relaxed); }

std::uint64_t now_ns() {
    return std::uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::high_resolution_clock::now().time_since_epoch()).count());
}
} // namespace

int main() {
    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    std::cout << "[md_consumer] Attaching to " << ipc::MD_SHM_NAME << " ...\n";
    try {
        ipc::SharedMemoryManager<ipc::MdRegion> shm(ipc::MD_SHM_NAME, false);
        ipc::MdRegion* region = shm.get();
        ipc::MdQueue*  queue  = &region->payload;

        // Handshake: wait for the bridge to finish initializing, then signal readiness.
        while (region->producer_ready.load(std::memory_order_acquire) == 0 &&
               g_running.load(std::memory_order_relaxed)) {
        }
        region->consumer_ready.store(1, std::memory_order_release);
        std::cout << "[md_consumer] Handshake complete. Draining top-of-book updates "
                     "(Ctrl-C to stop)...\n";

        std::uint64_t count = 0;
        while (g_running.load(std::memory_order_relaxed)) {
            auto opt = queue->pop();
            if (opt.has_value()) {
                const auto& t = opt.value();
                long long latency = static_cast<long long>(now_ns()) -
                                    static_cast<long long>(t.timestamp_ns);
                std::cout << "[md_consumer] TOB #" << ++count
                          << "  price=" << t.price
                          << "  vol="   << t.volume
                          << "  wire->queue=" << latency << " ns\n";
            }
            // Empty -> keep spinning (no sleep/yield on the low-latency path).
        }
        std::cout << "[md_consumer] Stopped after " << count << " updates.\n";
    } catch (const std::exception& e) {
        std::cerr << "[md_consumer ERROR] " << e.what()
                  << " (is mac_uart_bridge running?)\n";
        return 1;
    }
    return 0;
}
