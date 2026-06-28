// uart_bridge_pty_test -- exercises the real mac_uart_bridge end-to-end on the host with
// no FPGA attached, using a pseudo-terminal as the "serial cable".
//
//   - Opens a pty pair; the SLAVE path is handed to a freshly spawned mac_uart_bridge,
//     which opens it exactly like a /dev/tty.usbserial device.
//   - This process plays two roles on the MASTER side:
//       (a) fake FPGA: parse the bridge's inbound MDP 3.0 frames, run a trivial software
//           bid book, and write back 14-byte top-of-book frames (the bridge's RTL twin).
//       (b) queue consumer: attach to /ercot_md_shm and drain the MarketDataTicks the
//           bridge's ingress thread pushes from those returned frames.
//   - Asserts the drained ticks match the expected top-of-book walk, proving the bridge's
//     feeder serialization, ingress sync-hunt + checksum, and SPSC push all work.
//
// Usage: uart_bridge_pty_test [path-to-mac_uart_bridge]   (default: ./mac_uart_bridge)

#include "ipc/SharedMemoryManager.hpp"
#include "ipc/MarketDataChannel.hpp"
#include "ipc/UartFraming.hpp"

#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <map>
#include <optional>
#include <vector>

#include <cstdlib>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

void set_nonblocking(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

void write_all(int fd, const std::uint8_t* p, std::size_t n) {
    std::size_t off = 0;
    while (off < n) {
        ssize_t w = ::write(fd, p + off, n - off);
        if (w > 0) off += std::size_t(w);
        else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        else break;
    }
}

struct TobUpdate { std::int64_t price; std::uint32_t vol; };

// Trivial software bid book: best = highest price with vol > 0.
class FakeFpga {
public:
    // Feed raw bytes from the bridge; returns a TOB frame to send back if the best level
    // changed as a result.
    std::optional<TobUpdate> feed(const std::uint8_t* data, std::size_t n) {
        std::optional<TobUpdate> change;
        for (std::size_t i = 0; i < n; ++i) {
            acc_.push_back(data[i]);
            if (!have_header_ && acc_.size() == ipc::MDP_HEADER_LEN) {
                msg_type_    = (std::uint16_t(acc_[0]) << 8) | acc_[1];
                payload_len_ = (std::size_t(acc_[18]) << 8) | acc_[19];
                have_header_ = true;
                if (payload_len_ == 0) reset();   // header-only frame
            } else if (have_header_ &&
                       acc_.size() == ipc::MDP_HEADER_LEN + payload_len_) {
                if (msg_type_ == ipc::MSG_INCREMENTAL && payload_len_ >= 12) {
                    std::int64_t  price = std::int64_t(ipc::wire::get_be64(&acc_[ipc::MDP_HEADER_LEN]));
                    std::uint32_t vol   = ipc::wire::get_be32(&acc_[ipc::MDP_HEADER_LEN + 8]);
                    if (apply(price, vol)) change = best();
                }
                reset();
            }
        }
        return change;
    }

private:
    bool apply(std::int64_t price, std::uint32_t vol) {
        if (vol == 0) book_.erase(price);
        else          book_[price] = vol;
        TobUpdate b = best();
        bool changed = !last_valid_ || b.price != last_.price || b.vol != last_.vol;
        if (b.vol != 0) { last_ = b; last_valid_ = true; }
        else            { last_valid_ = false; }
        return changed && b.vol != 0;
    }
    TobUpdate best() const {
        if (book_.empty()) return { 0, 0 };
        auto it = book_.rbegin();   // highest price = best bid
        return { it->first, it->second };
    }
    void reset() { acc_.clear(); have_header_ = false; }

    std::vector<std::uint8_t>           acc_;
    std::map<std::int64_t, std::uint32_t> book_;
    bool         have_header_ = false;
    std::size_t  payload_len_ = 0;
    std::uint16_t msg_type_   = 0;
    TobUpdate    last_{ 0, 0 };
    bool         last_valid_  = false;
};

} // namespace

int main(int argc, char** argv) {
    const char* bridge_bin = (argc > 1) ? argv[1] : "./mac_uart_bridge";

    // ---- Create the pty pair ("serial cable") ----
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) {
        std::cerr << "RESULT: FAIL (posix_openpt setup: " << std::strerror(errno) << ")\n";
        return 1;
    }
    const char* slave_path = ptsname(master);
    if (!slave_path) {
        std::cerr << "RESULT: FAIL (ptsname failed)\n";
        return 1;
    }
    std::string slave(slave_path);

    // ---- Spawn the real bridge, pointed at the slave end ----
    pid_t pid = fork();
    if (pid < 0) { std::cerr << "RESULT: FAIL (fork)\n"; return 1; }
    if (pid == 0) {
        execl(bridge_bin, bridge_bin, slave.c_str(), static_cast<char*>(nullptr));
        std::cerr << "[test child] execl(" << bridge_bin << ") failed: "
                  << std::strerror(errno) << "\n";
        _exit(127);
    }

    set_nonblocking(master);

    int rc = 0;
    try {
        // ---- Attach as the queue consumer + complete the handshake ----
        ipc::SharedMemoryManager<ipc::MdRegion> shm(ipc::MD_SHM_NAME, false);
        ipc::MdRegion* region = shm.get();
        ipc::MdQueue*  queue  = &region->payload;
        while (region->producer_ready.load(std::memory_order_acquire) == 0) { }
        region->consumer_ready.store(1, std::memory_order_release);

        // ---- Fake-FPGA + drain loop ----
        FakeFpga fpga;
        std::vector<ipc::MarketDataTick> got;
        const std::vector<TobUpdate> expected = { {100, 10}, {105, 20}, {103, 5} };

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (got.size() < expected.size() &&
               std::chrono::steady_clock::now() < deadline) {
            // (a) fake FPGA: consume inbound frames, emit top-of-book on change.
            std::uint8_t buf[256];
            ssize_t n = ::read(master, buf, sizeof(buf));
            if (n > 0) {
                if (auto upd = fpga.feed(buf, std::size_t(n))) {
                    auto frame = ipc::wire::build_tob_frame(upd->price, upd->vol);
                    write_all(master, frame.data(), frame.size());
                }
            }
            // (b) consumer: drain whatever the bridge ingress pushed.
            if (auto t = queue->pop()) got.push_back(*t);
        }

        // ---- Verify ----
        if (got.size() != expected.size()) {
            std::cerr << "got " << got.size() << " ticks, expected " << expected.size() << "\n";
            rc = 1;
        }
        for (std::size_t i = 0; i < got.size() && i < expected.size(); ++i) {
            std::cout << "[test] tick " << i << ": price=" << got[i].price
                      << " vol=" << got[i].volume
                      << " ts_ns=" << got[i].timestamp_ns << "\n";
            if (got[i].price != expected[i].price || got[i].volume != expected[i].vol) {
                std::cerr << "  mismatch: expected " << expected[i].price
                          << "/" << expected[i].vol << "\n";
                rc = 1;
            }
            if (got[i].timestamp_ns == 0) {
                std::cerr << "  tick " << i << " has no ingress timestamp\n";
                rc = 1;
            }
        }
    } catch (const std::exception& e) {
        std::cerr << "[test] exception: " << e.what() << "\n";
        rc = 1;
    }

    // ---- Tear down the bridge ----
    kill(pid, SIGTERM);
    int status = 0;
    waitpid(pid, &status, 0);
    close(master);

    if (rc == 0)
        std::cout << "RESULT: PASS (bridge feeder + zero-yield ingress round-trip over pty)\n";
    else
        std::cout << "RESULT: FAIL\n";
    return rc;
}
