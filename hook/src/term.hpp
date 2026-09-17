#pragma once

#include <functional>
#include <optional>
#include <string>
#include <sys/types.h>

namespace hook {

// What sysctl KERN_PROC_PID gives us about one process. tdev is the
// controlling terminal's device number, or -1 (NODEV) for none.
struct ProcEntry {
    pid_t pid = 0;
    pid_t ppid = 0;
    std::string comm;
    dev_t tdev = static_cast<dev_t>(-1);
};

// Walks from `start` upward through `lookup`, skipping sh/bash/zsh/dash/env,
// and returns the first non-shell ancestor. Stops (returns nullopt) before
// ever looking up pid 1, or if `lookup` can't find an ancestor. Takes the
// lookup as a parameter so tests can hand it a fake ancestry chain instead
// of depending on the real process tree.
std::optional<ProcEntry> walk_to_agent(pid_t start,
                                        const std::function<std::optional<ProcEntry>(pid_t)>& lookup);

// Real sysctl(KERN_PROC_PID) lookup.
std::optional<ProcEntry> real_proc_lookup(pid_t pid);

// "/dev/ttysNNN" for a controlling-terminal device number, or nullopt for
// NODEV or a devname() miss.
std::optional<std::string> tty_path(dev_t tdev);

struct Term {
    std::optional<pid_t> pid;
    std::optional<std::string> tty;
    std::optional<std::string> program;
    std::optional<std::string> cmux_surface;
    std::optional<std::string> cmux_workspace;
    std::optional<std::string> cmux_socket;
    std::optional<std::string> cmux_cli;
};

// Real process tree and environment: walk_to_agent from getppid(), plus
// TERM_PROGRAM and the CMUX_* env vars.
Term current_term();

}  // namespace hook
