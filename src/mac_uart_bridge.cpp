// mac_uart_bridge -- macOS user-space serial bridge between the Basys 3 FPGA fast-path
// and the Phase 1 lock-free IPC layer. Single process, two pinned threads sharing one
// raw, non-blocking serial fd (115200 8N1):
//
//   Feeder thread (TX): streams a set of synthetic MDP 3.0 / SBE frames to the FPGA RX,
//       pacing them so the 115200-baud link never overflows.
//   Ingress thread (RX): a zero-yield poll loop -- no sleep, no blocking read -- that
//       reassembles the FPGA's 14-byte top-of-book frames and pushes each, as a
//       MarketDataTick, into a dedicated lock-free SPSC shared-memory queue.
//
// The Phase 1 ErcotTelemetry queue is left untouched; this owns its own /ercot_md_shm.
//
// Usage: mac_uart_bridge [/dev/tty.usbserial-XXXX]   (default: /dev/tty.usbserial)

#include "ipc/SharedMemoryManager.hpp"
#include "ipc/MarketDataChannel.hpp"
#include "ipc/UartFraming.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <cerrno>
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

#include <pthread.h>
#if defined(__APPLE__)
#  include <mach/mach.h>
#  include <mach/thread_policy.h>
#else
#  include <sched.h>
#endif

namespace {

std::atomic<bool> g_running{true};

void on_signal(int) { g_running.store(false, std::memory_order_relaxed); }

std::uint64_t now_ns() {
    return std::uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::high_resolution_clock::now().time_since_epoch()).count());
}

// Best-effort core pinning. macOS (esp. Apple Silicon) has no real CPU affinity API --
// THREAD_AFFINITY_POLICY is only an L2-sharing hint and is ignored on the SoCs -- so we
// also raise QoS to USER_INTERACTIVE to keep the thread on a performance core. On Linux
// this is a hard affinity set.
void pin_thread(int tag) {
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    thread_affinity_policy_data_t pol{ tag };
    thread_policy_set(pthread_mach_thread_np(pthread_self()),
                      THREAD_AFFINITY_POLICY, reinterpret_cast<thread_policy_t>(&pol),
                      THREAD_AFFINITY_POLICY_COUNT);
#else
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(tag, &set);
    pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#endif
}

// Open the serial port raw + non-blocking at 115200 8N1, no flow control.
int open_serial(const char* path) {
    int fd = ::open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        throw std::runtime_error(std::string("open(") + path + ") failed: " + std::strerror(errno));

    struct termios tio{};
    if (tcgetattr(fd, &tio) != 0) {
        ::close(fd);
        throw std::runtime_error(std::string("tcgetattr failed: ") + std::strerror(errno));
    }
    cfmakeraw(&tio);
    cfsetispeed(&tio, B115200);
    cfsetospeed(&tio, B115200);
    tio.c_cflag |= (CLOCAL | CREAD);          // ignore modem lines, enable receiver
    tio.c_cflag &= ~(PARENB | CSTOPB);        // 8N1
    tio.c_cflag &= ~CSIZE; tio.c_cflag |= CS8;
#ifdef CRTSCTS
    tio.c_cflag &= ~CRTSCTS;                  // no hardware flow control
#endif
    tio.c_cc[VMIN]  = 0;                       // fully non-blocking reads
    tio.c_cc[VTIME] = 0;
    if (tcsetattr(fd, TCSANOW, &tio) != 0) {
        ::close(fd);
        throw std::runtime_error(std::string("tcsetattr failed: ") + std::strerror(errno));
    }
    return fd;
}

// Write all n bytes, tolerating partial / EAGAIN writes on the non-blocking fd.
void write_all(int fd, const std::uint8_t* p, std::size_t n) {
    std::size_t off = 0;
    while (off < n && g_running.load(std::memory_order_relaxed)) {
        ssize_t w = ::write(fd, p + off, n - off);
        if (w > 0) {
            off += std::size_t(w);
        } else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;  // kernel TX buffer full; retry
        } else if (w < 0 && errno == EINTR) {
            continue;
        } else {
            break;     // hard error
        }
    }
}

// ---- Feeder (TX): stream synthetic MDP 3.0 frames to the FPGA, paced ----
void feeder_loop(int fd) {
    pin_thread(1);

    struct Vec { std::uint16_t type; std::int64_t price; std::uint32_t vol; };
    // A small deterministic scenario for a bid book: two inserts, a non-improving
    // insert, then delete the best level (vol==0). The FPGA's top-of-book should walk
    // 100/10 -> 105/20 -> (unchanged) -> 103/5.
    const std::vector<Vec> vectors = {
        { ipc::MSG_INCREMENTAL, 100, 10 },
        { ipc::MSG_INCREMENTAL, 105, 20 },
        { ipc::MSG_INCREMENTAL, 103,  5 },
        { ipc::MSG_INCREMENTAL, 105,  0 },  // delete best
    };

    for (const auto& v : vectors) {
        if (!g_running.load(std::memory_order_relaxed)) break;
        auto frame = ipc::wire::build_mdp_frame(v.type, v.price, v.vol);
        write_all(fd, frame.data(), frame.size());
        // Pace so the 115200 link (~11.5 KB/s) is never overrun.
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    std::cerr << "[bridge] feeder: sent " << vectors.size()
              << " synthetic MDP frames; idling.\n";
    // Nothing more to send; the ingress thread keeps the process alive until shutdown.
}

// ---- Ingress (RX): zero-yield poll, reassemble TOB frames, push to the queue ----
void ingress_loop(int fd, ipc::MdQueue* queue) {
    pin_thread(2);

    std::uint8_t rbuf[256];
    std::uint8_t frame[ipc::TOB_FRAME_LEN];
    std::size_t  cnt = 0;
    bool         hunting = true;       // searching for the 0xAA sync byte
    std::uint64_t pushed = 0, dropped = 0;

    while (g_running.load(std::memory_order_relaxed)) {
        // Aggressive non-blocking read. No sleep / no yield: when nothing is available
        // read() returns -1/EAGAIN and we immediately loop again to catch bytes the
        // instant they land.
        ssize_t n = ::read(fd, rbuf, sizeof(rbuf));
        if (n <= 0) continue;

        for (ssize_t i = 0; i < n; ++i) {
            std::uint8_t b = rbuf[i];
            if (hunting) {
                if (b == ipc::TOB_SYNC) { frame[0] = b; cnt = 1; hunting = false; }
            } else {
                frame[cnt++] = b;
                if (cnt == ipc::TOB_FRAME_LEN) {
                    if (ipc::wire::tob_checksum(frame) == frame[ipc::TOB_FRAME_LEN - 1]) {
                        ipc::MarketDataTick tick;
                        tick.price        = std::int64_t(ipc::wire::get_be64(&frame[1]));
                        tick.volume       = ipc::wire::get_be32(&frame[9]);
                        tick.timestamp_ns = now_ns();   // stamp at wire arrival
                        // Spin-push (never sleep on the hot path); bail on shutdown.
                        while (!queue->push(tick) &&
                               g_running.load(std::memory_order_relaxed)) {
                        }
                        ++pushed;
                    } else {
                        ++dropped;  // checksum mismatch -> resync from the next sync byte
                    }
                    hunting = true;
                    cnt = 0;
                }
            }
        }
    }
    std::cerr << "[bridge] ingress: pushed " << pushed << " ticks, dropped "
              << dropped << " (bad checksum).\n";
}

} // namespace

int main(int argc, char** argv) {
    const char* dev = (argc > 1) ? argv[1] : "/dev/tty.usbserial";

    std::signal(SIGINT,  on_signal);
    std::signal(SIGTERM, on_signal);

    try {
        int fd = open_serial(dev);
        std::cerr << "[bridge] opened " << dev << " (115200 8N1, raw, non-blocking).\n";

        // Create the dedicated market-data shared-memory region (producer/creator side).
        ipc::SharedMemoryManager<ipc::MdRegion> shm(ipc::MD_SHM_NAME, true);
        ipc::MdRegion* region = shm.get();
        ipc::MdQueue*  queue  = &region->payload;

        // Startup handshake: announce readiness, then wait (startup-only spin, off the
        // hot path) for a consumer to attach before we begin streaming into the queue.
        region->producer_ready.store(1, std::memory_order_release);
        std::cerr << "[bridge] queue ready at " << ipc::MD_SHM_NAME
                  << "; waiting for a consumer...\n";
        while (region->consumer_ready.load(std::memory_order_acquire) == 0 &&
               g_running.load(std::memory_order_relaxed)) {
        }
        if (!g_running.load(std::memory_order_relaxed)) { ::close(fd); return 0; }
        std::cerr << "[bridge] consumer attached; starting feeder + ingress.\n";

        std::thread feeder (feeder_loop,  fd);
        std::thread ingress(ingress_loop, fd, queue);

        feeder.join();    // returns after the synthetic burst
        ingress.join();   // returns on SIGINT/SIGTERM

        ::close(fd);
    } catch (const std::exception& e) {
        std::cerr << "[bridge ERROR] " << e.what() << "\n";
        return 1;
    }
    return 0;
}
