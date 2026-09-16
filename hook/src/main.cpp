#include "decide.hpp"
#include "envelope.hpp"
#include "scan.hpp"
#include "sock.hpp"
#include "term.hpp"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <optional>
#include <string>
#include <sys/time.h>
#include <unistd.h>

namespace {

int64_t now_ms() {
    timeval tv{};
    ::gettimeofday(&tv, nullptr);
    return static_cast<int64_t>(tv.tv_sec) * 1000 + tv.tv_usec / 1000;
}

// Always drains stdin to EOF, even on a path that won't use the bytes:
// quitting early risks EPIPE on Claude's side of the pipe.
std::string read_stdin_to_eof() {
    std::string data;
    char buf[65536];
    for (;;) {
        const ssize_t n = ::read(0, buf, sizeof(buf));
        if (n > 0) { data.append(buf, static_cast<size_t>(n)); continue; }
        if (n == 0) break;  // EOF
        if (errno == EINTR) continue;
        break;  // some other read error: best effort, move on
    }
    return data;
}

std::optional<hook::Client> parse_client(int argc, char** argv) {
    for (int i = 1; i < argc - 1; ++i) {
        if (std::string(argv[i]) == "--client") {
            const std::string v = argv[i + 1];
            if (v == "claude") return hook::Client::claude;
            if (v == "codex") return hook::Client::codex;
            return std::nullopt;
        }
    }
    return std::nullopt;
}

void write_stdout_line(const std::string& line) {
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fputc('\n', stdout);
}

int run(int argc, char** argv) {
    const auto client = parse_client(argc, argv);
    const std::string input = read_stdin_to_eof();
    if (!client) return 0;  // missing or unknown --client: nothing sent

    const hook::ScanOutput scan = hook::scan(input);

    hook::EnvelopeOptions opts;
    opts.client = *client;
    opts.ts_ms = now_ms();
    opts.term = hook::current_term();

    const hook::Paths paths = hook::paths_from_environment();

    if (hook::wants_decision(scan.scalars)) {
        opts.decide = true;
        const auto line = hook::build_envelope(scan, opts);
        if (!line) return 0;
        const auto reply = hook::wait_for_decision(paths.decide(), *line + "\n", opts.term.pid);
        if (!reply) return 0;
        if (const auto output = hook::hook_output(hook::parse_reply(*reply))) {
            write_stdout_line(*output);
        }
        return 0;
    }

    if (const auto line = hook::build_envelope(scan, opts)) {
        hook::send_event(paths.events(), *line + "\n", /*budget_ms=*/2);
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    ::signal(SIGPIPE, SIG_IGN);
    try {
        return run(argc, argv);
    } catch (...) {
        return 0;  // silence is the whole contract: never let an exception out
    }
}
