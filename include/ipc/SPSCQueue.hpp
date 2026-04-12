#pragma once

#include <atomic>
#include <cstddef>
#include <array>
#include <optional>

namespace ipc {

// A Single-Producer Single-Consumer (SPSC) Lock-Free Circular Buffer.
template<typename T, size_t Capacity>
class SPSCQueue {
public:
    SPSCQueue() : head_(0), tail_(0) {}

    // Called strictly by the Producer Thread/Process
    bool push(const T& item) {
        const size_t current_tail = tail_.load(std::memory_order_relaxed);
        const size_t next_tail = (current_tail + 1) % Capacity;

        // Consumer modifies head_. We must use memory_order_acquire 
        // to guarantee all writes by the consumer are visible before proceeding.
        if (next_tail == head_.load(std::memory_order_acquire)) {
            return false; // Queue is full
        }

        buffer_[current_tail] = item;
        
        // Use memory_order_release to ensure the struct data is fully written to memory 
        // BEFORE the tail index updates to indicate it is available.
        tail_.store(next_tail, std::memory_order_release);
        return true;
    }

    // Called strictly by the Consumer Thread/Process
    std::optional<T> pop() {
        const size_t current_head = head_.load(std::memory_order_relaxed);

        // Producer modifies tail_. We use memory_order_acquire to ensure
        // we strictly see everything up to the producer's tail update.
        if (current_head == tail_.load(std::memory_order_acquire)) {
            return std::nullopt; // Queue is empty
        }

        T item = buffer_[current_head];
        
        // memory_order_release guarantees we signal the read completion
        // only after the struct is truly popped from the buffer.
        head_.store((current_head + 1) % Capacity, std::memory_order_release);
        return item;
    }

private:
    // False sharing notes:
    // L1 Cache Line typically 64 B
    // if head and tail on the same cache line: producer (core 0) and consumer (core 1) cause **False Sharing** = cache coherency invalidaitons
    // Using alignas(64) for boundary on both integer atomics
    
    alignas(64) std::atomic<size_t> head_;
    alignas(64) std::atomic<size_t> tail_;

    // The contiguous block of ring memory.
    std::array<T, Capacity> buffer_;
};

} // namespace ipc
