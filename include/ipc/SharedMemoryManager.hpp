#pragma once

#include <string>
#include <stdexcept>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <iostream>

namespace ipc {

template<typename T>
class SharedMemoryManager {
public:
    // is_creator determines if this process should create and initialize the memory (Producer)
    // or just attach to an existing memory block (Consumer).
    SharedMemoryManager(const std::string& name, bool is_creator) 
        : name_(name), is_creator_(is_creator), ptr_(nullptr) {
        
        int oflag = O_RDWR;
        if (is_creator_) {
            oflag |= O_CREAT | O_TRUNC; // Create new, truncate if exists
        }

        // 1. Open the shared memory object
        fd_ = shm_open(name_.c_str(), oflag, 0666);
        if (fd_ == -1) {
            throw std::runtime_error("shm_open failed");
        }

        // 2. Set the size of the shared memory object
        if (is_creator_) {
            if (ftruncate(fd_, sizeof(T)) == -1) {
                close(fd_);
                throw std::runtime_error("ftruncate failed");
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
