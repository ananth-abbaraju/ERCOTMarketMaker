#pragma once

#include <string>
#include <stdexcept>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <iostream>
#include <cerrno>
#include <new>
#include <chrono>
#include <thread>

namespace ipc {

template<typename T>
class SharedMemoryManager {
public:
    // is_creator determines if this process should create and initialize the memory (Producer)
    // or just attach to an existing memory block (Consumer).
    SharedMemoryManager(const std::string& name, bool is_creator)
        : name_(name), is_creator_(is_creator), fd_(-1), ptr_(nullptr) {

        if (is_creator_) {
            // 1a. Create (truncating any stale segment) and size the object up front.
            fd_ = shm_open(name_.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0666);
            if (fd_ == -1) {
                throw std::runtime_error("shm_open (create) failed");
            }
            if (ftruncate(fd_, sizeof(T)) == -1) {
                close(fd_);
                throw std::runtime_error("ftruncate failed");
            }
        } else {
            // 1b. Attach mode. The creator may not have run yet, and even once the
            // segment exists it may not be sized (ftruncate) before we map it --
            // mmap'ing a zero-length object and then touching it raises SIGBUS.
            // So poll until the segment both EXISTS and is large enough, bounded by
            // a timeout. This is startup-only (off the hot path), so a tiny sleep
            // between attempts is fine and avoids pegging a core.
            const auto deadline =
                std::chrono::steady_clock::now() + std::chrono::seconds(5);

            while ((fd_ = shm_open(name_.c_str(), O_RDWR, 0666)) == -1) {
                if (errno != ENOENT ||
                    std::chrono::steady_clock::now() > deadline) {
                    throw std::runtime_error(
                        "shm_open (attach) timed out waiting for the producer");
                }
                std::this_thread::sleep_for(std::chrono::microseconds(200));
            }

            struct stat st{};
            while (fstat(fd_, &st) != 0 ||
                   static_cast<size_t>(st.st_size) < sizeof(T)) {
                if (std::chrono::steady_clock::now() > deadline) {
                    close(fd_);
                    throw std::runtime_error(
                        "attach timed out waiting for the segment to be sized");
                }
                std::this_thread::sleep_for(std::chrono::microseconds(200));
            }
        }

        // 3. Map into the process's virtual address space
        void* raw_ptr = mmap(nullptr, sizeof(T), PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
        if (raw_ptr == MAP_FAILED) {
            close(fd_);
            throw std::runtime_error("mmap failed");
        }

        ptr_ = static_cast<T*>(raw_ptr);

        // 4. Initialize the object via placement-new if we are the creator
        if (is_creator_) {
            new (ptr_) T(); 
        }
    }

    ~SharedMemoryManager() {
        if (ptr_) {
            munmap(ptr_, sizeof(T));
        }
        if (fd_ != -1) {
            close(fd_);
        }
        if (is_creator_) {
            // Only the creator is responsible for unlinking (destroying) the shm object
            shm_unlink(name_.c_str());
        }
    }

    T* get() const { return ptr_; }

private:
    std::string name_;
    bool is_creator_;
    int fd_;
    T* ptr_;
};

} // namespace ipc
