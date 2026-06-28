#include "ipc/SharedMemoryManager.hpp"
#include "ipc/SPSCQueue.hpp"
#include "ipc/ErcotTelemetry.hpp"
#include "ipc/HandshakeRegion.hpp"

#include <iostream>
#include <chrono>
#include <limits>

constexpr size_t QUEUE_CAPACITY = 1024 * 64;

using ErcotQueue = ipc::SPSCQueue<ipc::ErcotTelemetry, QUEUE_CAPACITY>;
using Region = ipc::HandshakeRegion<ErcotQueue>;

int main() {
    std::cout << "[Consumer] Attaching to Shared Memory...\n";

    // The consumer attaches to the shared memory block (creating nothing, unlinking
    // nothing). The manager now waits for the segment to exist and be sized, so the
    // consumer may even be launched before the producer.
    try {
        ipc::SharedMemoryManager<Region> shm("/ercot_queue_shm", false);
        Region* region = shm.get();
        ErcotQueue* queue = &region->payload;

        // Handshake: wait for the producer to finish initializing the region, then
        // signal that we are attached and ready to drain.
        while (region->producer_ready.load(std::memory_order_acquire) == 0) {
        }
        region->consumer_ready.store(1, std::memory_order_release);

        std::cout << "[Consumer] Handshake complete. Draining queue... (spin-lock polling)\n";

        const int TOTAL_TICKS_EXPECTED = 5'000'000;
        int ticks_received = 0;

        long long total_latency_ns = 0;
        long long max_latency_ns = 0;
        long long min_latency_ns = std::numeric_limits<long long>::max();

        // Start the throughput clock on the FIRST tick actually received, not before.
        // (Previously the timer started while still spinning on an empty queue, which
        // folded idle wait time into the measured drain time.)
        std::chrono::high_resolution_clock::time_point start{};
        bool started = false;

        while (ticks_received < TOTAL_TICKS_EXPECTED) {
            auto optional_tick = queue->pop();
            if (optional_tick.has_value()) {
                const auto& tick = optional_tick.value();
                auto received_time_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                            std::chrono::high_resolution_clock::now().time_since_epoch()
                                        ).count();

                if (!started) {
                    start = std::chrono::high_resolution_clock::now();
                    started = true;
                }

                long long latency = received_time_ns - static_cast<long long>(tick.timestamp_ns);

                total_latency_ns += latency;
                if (latency > max_latency_ns) max_latency_ns = latency;
                if (latency < min_latency_ns) min_latency_ns = latency;

                ticks_received++;
            } else {
                // If queue is empty, KEEP SPINNING.
                // Do NOT yield or sleep in a low-latency systems application!
            }
        }

        auto end = std::chrono::high_resolution_clock::now();
        auto duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        double throughput_m = (duration_ms > 0)
                                  ? static_cast<double>(ticks_received) / duration_ms / 1000.0
                                  : 0.0;

        // Note on interpretation: the producer bursts ~20M ticks/s, far faster than a
        // single consumer drains, so the ring stays full and most ticks sit queued.
        // => the AVERAGE below is dominated by queue-residence time under load, NOT the
        //    core-to-core transfer cost. The MIN (seen while the ring is still shallow)
        //    is the honest approximation of the raw enqueue->dequeue hop.
        std::cout << "\n[Consumer] Received " << ticks_received << " ticks; drained in " << duration_ms << " ms.\n";
        std::cout << "[Consumer]   --- enqueue -> dequeue latency ---\n";
        std::cout << "[Consumer]   Min : " << min_latency_ns << " ns   (~ raw core-to-core hop)\n";
        std::cout << "[Consumer]   Avg : " << total_latency_ns / ticks_received << " ns   (incl. queue residence under load)\n";
        std::cout << "[Consumer]   Max : " << max_latency_ns << " ns\n";
        std::cout << "[Consumer]   Throughput : " << throughput_m << " M ticks/s\n";

        std::cout << "[Consumer] Exiting.\n";

    } catch (const std::exception& e) {
        std::cerr << "[Consumer ERROR] " << e.what() 
                  << " (Did you forget to start the Producer first?)\n";
    }

    return 0;
}
