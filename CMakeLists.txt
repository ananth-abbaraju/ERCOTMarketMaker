cmake_minimum_required(VERSION 3.20)
project(TradingIPC VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Compiler flags for maximum performance and strict warnings
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -Wall -Wextra -pthread -march=native")

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)

# OS-specific link libraries for POSIX shared memory (shm_open)
# macOS includes shm_open in libc, but Linux requires -lrt
set(IPC_LIBS pthread)
if (CMAKE_SYSTEM_NAME MATCHES "Linux")
    list(APPEND IPC_LIBS rt)
endif()

# We will add executable targets for Producer and Consumer next!
add_executable(producer src/producer.cpp)
target_link_libraries(producer PRIVATE ${IPC_LIBS})

add_executable(consumer src/consumer.cpp)
target_link_libraries(consumer PRIVATE ${IPC_LIBS})
