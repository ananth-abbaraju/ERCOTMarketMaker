cmake_minimum_required(VERSION 3.20)
project(TradingIPC VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Compiler flags for maximum performance and strict warnings
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -Wall -Wextra -pthread -march=native")

# We build in strict-standard mode (-std=c++20), which sets __STRICT_ANSI__ and hides
# BSD/Darwin extensions the UART bridge relies on (cfmakeraw, posix_openpt, the Mach
# thread-policy QoS calls). Re-expose them on Apple.
if (APPLE)
    add_compile_definitions(_DARWIN_C_SOURCE)
endif()

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)

# OS-specific link libraries for POSIX shared memory (shm_open)
# macOS includes shm_open in libc, but Linux requires -lrt
set(IPC_LIBS pthread)
if (CMAKE_SYSTEM_NAME MATCHES "Linux")
    list(APPEND IPC_LIBS rt)
endif()

# Phase 1: lock-free IPC demo (grid telemetry).
add_executable(producer src/producer.cpp)
target_link_libraries(producer PRIVATE ${IPC_LIBS})

add_executable(consumer src/consumer.cpp)
target_link_libraries(consumer PRIVATE ${IPC_LIBS})

# Phase 2.5: FPGA <-> Mac UART bridge + dedicated market-data queue.
add_executable(mac_uart_bridge src/mac_uart_bridge.cpp)
target_link_libraries(mac_uart_bridge PRIVATE ${IPC_LIBS})

add_executable(md_consumer src/md_consumer.cpp)
target_link_libraries(md_consumer PRIVATE ${IPC_LIBS})

# Host-side end-to-end test of the bridge over a pseudo-terminal (no FPGA required).
enable_testing()
add_executable(uart_bridge_pty_test tests/uart_bridge_pty_test.cpp)
target_link_libraries(uart_bridge_pty_test PRIVATE ${IPC_LIBS})
add_test(NAME uart_bridge_pty
         COMMAND uart_bridge_pty_test $<TARGET_FILE:mac_uart_bridge>)
