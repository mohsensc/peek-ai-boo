#include "term.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace hook {

std::optional<ProcEntry> walk_to_agent(pid_t start,
                                        const std::function<std::optional<ProcEntry>(pid_t)>& lookup) {
    static constexpr std::array<const char*, 5> kShells = {"sh", "bash", "zsh", "dash", "env"};
    pid_t pid = start;
    while (pid > 1) {
        const auto entry = lookup(pid);
        if (!entry) return std::nullopt;
        const bool is_shell = std::any_of(kShells.begin(), kShells.end(), [&](const char* name) {
            return entry->comm == name;
        });
        if (!is_shell) return entry;
        pid = entry->ppid;
    }
    return std::nullopt;
}

std::optional<ProcEntry> real_proc_lookup(pid_t pid) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info {};
    size_t len = sizeof(info);
    if (::sysctl(mib, 4, &info, &len, nullptr, 0) != 0 || len == 0) return std::nullopt;

    ProcEntry entry;
    entry.pid = info.kp_proc.p_pid;
    entry.ppid = info.kp_eproc.e_ppid;
    entry.comm = std::string(info.kp_proc.p_comm, ::strnlen(info.kp_proc.p_comm, sizeof(info.kp_proc.p_comm)));
    entry.tdev = info.kp_eproc.e_tdev;
    return entry;
}

std::optional<std::string> tty_path(dev_t tdev) {
    if (tdev == static_cast<dev_t>(-1)) return std::nullopt;
    const char* name = ::devname(tdev, S_IFCHR);
    if (name == nullptr || name[0] == '#') return std::nullopt;  // devname() couldn't resolve it
    return std::string("/dev/") + name;
}

namespace {
std::optional<std::string> env(const char* name) {
    const char* v = std::getenv(name);
    if (v == nullptr || v[0] == '\0') return std::nullopt;
    return std::string(v);
}
}  // namespace

Term current_term() {
    Term term;
    if (const auto agent = walk_to_agent(::getppid(), real_proc_lookup)) {
        term.pid = agent->pid;
        term.tty = tty_path(agent->tdev);
    }
    term.program = env("TERM_PROGRAM");
    term.cmux_surface = env("CMUX_SURFACE_ID");
    term.cmux_workspace = env("CMUX_WORKSPACE_ID");
    term.cmux_socket = env("CMUX_SOCKET_PATH");
    term.cmux_cli = env("CMUX_BUNDLED_CLI_PATH");
    return term;
}

}  // namespace hook
