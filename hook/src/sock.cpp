#include "sock.hpp"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace hook {
namespace {

using Clock = std::chrono::steady_clock;

int remaining_ms(Clock::time_point start, int budget_ms) {
    const auto spent = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
    const long left = static_cast<long>(budget_ms) - static_cast<long>(spent);
    return left > 0 ? static_cast<int>(left) : 0;
}

void set_nosigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    const int on = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#else
    (void)fd;
#endif
}

// A connected, non-blocking socket within `budget_ms` of `start`, or -1.
int connect_nonblocking(const std::string& path, Clock::time_point start, int budget_ms) {
    if (path.empty() || path.size() >= sizeof(sockaddr_un::sun_path)) return -1;

    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    set_nosigpipe(fd);

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.c_str());

    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        if (errno != EINPROGRESS && errno != EAGAIN) {
            ::close(fd);
            return -1;
        }
        pollfd pfd{fd, POLLOUT, 0};
        const int left = remaining_ms(start, budget_ms);
        if (left == 0 || ::poll(&pfd, 1, left) != 1 || (pfd.revents & POLLOUT) == 0) {
            ::close(fd);
            return -1;
        }
        int err = 0;
        socklen_t len = sizeof(err);
        if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
            ::close(fd);
            return -1;
        }
    }
    return fd;
}

bool send_all_nonblocking(int fd, const std::string& payload, Clock::time_point start, int budget_ms) {
#ifdef MSG_NOSIGNAL
    constexpr int kFlags = MSG_NOSIGNAL;
#else
    constexpr int kFlags = 0;
#endif
    size_t sent = 0;
    while (sent < payload.size()) {
        const ssize_t n = ::send(fd, payload.data() + sent, payload.size() - sent, kFlags);
        if (n > 0) {
            sent += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            const int left = remaining_ms(start, budget_ms);
            if (left == 0) return false;
            pollfd pfd{fd, POLLOUT, 0};
            if (::poll(&pfd, 1, left) != 1 || (pfd.revents & POLLOUT) == 0) return false;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        return false;
    }
    return true;
}

// A connected, blocking socket, or -1. Decide has no latency budget of its
// own -- the hook entry's timeout is the cap -- so a plain blocking
// connect is enough and a lot less code than the events.sock path.
int connect_blocking(const std::string& path) {
    if (path.empty() || path.size() >= sizeof(sockaddr_un::sun_path)) return -1;
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    set_nosigpipe(fd);

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.c_str());

    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

bool send_all_blocking(int fd, const std::string& payload) {
#ifdef MSG_NOSIGNAL
    constexpr int kFlags = MSG_NOSIGNAL;
#else
    constexpr int kFlags = 0;
#endif
    size_t sent = 0;
    while (sent < payload.size()) {
        const ssize_t n = ::send(fd, payload.data() + sent, payload.size() - sent, kFlags);
        if (n > 0) { sent += static_cast<size_t>(n); continue; }
        if (n < 0 && errno == EINTR) continue;
        return false;
    }
    return true;
}

constexpr size_t kMaxReply = 64 * 1024;

}  // namespace

std::string Paths::events() const { return dir + "/events.sock"; }
std::string Paths::decide() const { return dir + "/decide.sock"; }

Paths paths_from_environment() {
    Paths p;
    if (const char* v = std::getenv("PEEKABOO_DIR"); v != nullptr && v[0] != '\0') {
        p.dir = v;
        return p;
    }
    if (const char* home = std::getenv("HOME"); home != nullptr && home[0] != '\0') {
        p.dir = std::string(home) + "/.peek-ai-boo";
    }
    return p;
}

void send_event(const std::string& sock_path, const std::string& line, int budget_ms) {
    if (sock_path.empty()) return;
    const auto start = Clock::now();
    const int fd = connect_nonblocking(sock_path, start, budget_ms);
    if (fd < 0) return;
    send_all_nonblocking(fd, line, start, budget_ms);
    ::close(fd);
}

std::optional<std::string> wait_for_decision(const std::string& sock_path, const std::string& line,
                                              std::optional<pid_t> term_pid) {
    if (sock_path.empty()) return std::nullopt;

    const int fd = connect_blocking(sock_path);
    if (fd < 0) return std::nullopt;
    if (!send_all_blocking(fd, line)) { ::close(fd); return std::nullopt; }
    ::shutdown(fd, SHUT_WR);

    const int kq = ::kqueue();
    if (kq < 0) { ::close(fd); return std::nullopt; }

    struct kevent changes[2];
    int n_changes = 0;
    EV_SET(&changes[n_changes++], fd, EVFILT_READ, EV_ADD, 0, 0, nullptr);
    if (term_pid) {
        EV_SET(&changes[n_changes++], *term_pid, EVFILT_PROC, EV_ADD, NOTE_EXIT, 0, nullptr);
    }
    // Register both at once: if the agent is already gone, this fails
    // with ESRCH and we exit quietly rather than wait on an empty room.
    if (::kevent(kq, changes, n_changes, nullptr, 0, nullptr) != 0) {
        ::close(kq);
        ::close(fd);
        return std::nullopt;
    }

    std::string buf;
    for (;;) {
        struct kevent ev{};
        const int r = ::kevent(kq, nullptr, 0, &ev, 1, nullptr);
        if (r < 0) {
            if (errno == EINTR) continue;
            ::close(kq);
            ::close(fd);
            return std::nullopt;
        }
        if (ev.filter == EVFILT_PROC) {
            ::close(kq);
            ::close(fd);
            return std::nullopt;  // the agent is gone: nobody's waiting on an answer
        }

        char chunk[4096];
        const ssize_t got = ::read(fd, chunk, sizeof(chunk));
        if (got < 0) {
            if (errno == EINTR) continue;
            ::close(kq);
            ::close(fd);
            return std::nullopt;
        }
        if (got == 0) {
            ::close(kq);
            ::close(fd);
            return std::nullopt;  // EOF with no newline: nothing worth acting on
        }
        buf.append(chunk, static_cast<size_t>(got));
        if (buf.size() > kMaxReply) {
            ::close(kq);
            ::close(fd);
            return std::nullopt;
        }
        if (const auto nl = buf.find('\n'); nl != std::string::npos) {
            ::close(kq);
            ::close(fd);
            return buf.substr(0, nl);
        }
    }
}

}  // namespace hook
