#include "ipc/SharedMemoryManager.hpp"
#include "ipc/SPSCQueue.hpp"
#include "ipc/ErcotTelemetry.hpp"

#include <iostream>
#include <chrono>

constexpr size_t QUEUE_CAPACITY = 1024 * 64; 

using ErcotQueue = ipc::SPSCQueue<ipc::ErcotTelemetry, QUEUE_CAPACITY>;

int main() {
    std::cout << "[Consumer] Attaching to Shared Memory...\n";

    // The consumer attaches to the ALREADY CREATED shared memory block
    // Passing false avoids attempting to unlink the shared memory on exit.
    try {
        ipc::SharedMemoryManager<ErcotQueue> shm("/ercot_queue_shm", false);
        ErcotQueue* queue = shm.get();

        std::cout << "[Consumer] Successfully attached to queue.\n";
        std::cout << "[Consumer] Polling for ERCOT telemetry... (Warning: Using spin-lock polling)\n";

        const int TOTAL_TICKS_EXPECTED = 5'000'000;
        int ticks_received = 0;
        
        long long total_latency_ns = 0;
        long long max_latency_ns = 0;

        auto start = std::chrono::high_resolution_clock::now();

        while (ticks_received < TOTAL_TICKS_EXPECTED) {
            auto optional_tick = queue->pop();
            if (optional_tick.has_value()) {
                auto tick = optional_tick.value();
                auto received_time_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                            std::chrono::high_resolution_clock::now().time_since_epoch()
                                        ).count();
                
                long long latency = received_time_ns - tick.timestamp_ns;
                
                total_latency_ns += latency;
                if (latency > max_latency_ns) {
                    max_latency_ns = latency;
                }

                ticks_received++;
            } else {
                // If queue is empty, KEEP SPINNING.
                // Do NOT yield or sleep in a low-latency systems application!
            }
        }
        
        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

        std::cout << "\n[Consumer] Received " << ticks_received << " telemetry ticks in " << duration << " ms.\n";
        std::cout << "[Consumer]   --- Latency Profile ---\n";
        std::cout << "[Consumer]   Average IPC Latency: " << total_latency_ns / ticks_received << " ns\n";
        std::cout << "[Consumer]   Maximum IPC Latency: " << max_latency_ns << " ns\n";
        
        std::cout << "[Consumer] Exiting.\n";

    } catch (const std::exception& e) {
        std::cerr << "[Consumer ERROR] " << e.what() 
                  << " (Did you forget to start the Producer first?)\n";
    }

    return 0;
}
