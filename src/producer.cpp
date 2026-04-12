#include "ipc/SharedMemoryManager.hpp"
#include "ipc/SPSCQueue.hpp"
#include "ipc/ErcotTelemetry.hpp"

#include <iostream>
#include <chrono>
#include <thread>

// An arbitrary capacity for the queue (power of 2 is good)
constexpr size_t QUEUE_CAPACITY = 1024 * 64; 

using ErcotQueue = ipc::SPSCQueue<ipc::ErcotTelemetry, QUEUE_CAPACITY>;

int main() {
    std::cout << "[Producer] Initializing Shared Memory...\n";

    // The producer acts as the "creator" of the shared memory object
    ipc::SharedMemoryManager<ErcotQueue> shm("/ercot_queue_shm", true);
    ErcotQueue* queue = shm.get();

    std::cout << "[Producer] Ready to stream telemetry data.\n";
    std::cout << "[Producer] Waiting 3 seconds for the consumer to attach...\n";
    std::this_thread::sleep_for(std::chrono::seconds(3));

    const int TOTAL_TICKS = 5'000'000;
    double dummy_frequency = 60.0;
    
    auto start_time = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < TOTAL_TICKS; ++i) {
        
        // Construct the dummy telemetry object
        ipc::ErcotTelemetry tick;
        
        // 1. Tag the high-resolution timestamp
        tick.timestamp_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                std::chrono::high_resolution_clock::now().time_since_epoch()
                            ).count();
        
        // 2. Add some "physical" telemetry
        tick.grid_frequency_hz = dummy_frequency;
        tick.nodal_price_usd = 23.50 + (i % 100) * 0.01;
        tick.wind_speed_mph = 15.2;
        tick.station_id = 1;

        // 3. Busy-wait (spin) until the queue has space to push
        while (!queue->push(tick)) {
            // This is a spin-lock.
            // DO NOT sleep/yield here; that invokes the kernel and destroys latency.
            // Since this is a test, keep spinning.
        }

        // Slightly perturb frequency to simulate real ERCOT grid behavior
        if (i % 10 == 0) {
            dummy_frequency += 0.001; 
        } else {
            dummy_frequency -= 0.001;
        }
    }

    auto end_time = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count();

    std::cout << "[Producer] Fired " << TOTAL_TICKS << " telemetry ticks in " 
              << duration << " ms.\n";
    
    std::cout << "[Producer] Shutting down. The shared memory block will be unlinked (destroyed).\n";

    return 0;
}
