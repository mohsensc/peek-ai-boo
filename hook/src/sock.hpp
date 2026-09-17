#pragma once

#include <optional>
#include <string>
#include <sys/types.h>

namespace hook {

struct Paths {
    std::string dir;  // empty means unset: caller sends nothing
    std::string events() const;
    std::string decide() const;
};

// $PEEKABOO_DIR, else $HOME/.peek-ai-boo. dir is empty if neither is set.
Paths paths_from_environment();

// Fire-and-forget: non-blocking connect then write, `budget_ms` total for
// both. Never blocks past the budget, never throws. Any failure -- no
// listener, full backlog, slow accept -- is silent.
void send_event(const std::string& sock_path, const std::string& line, int budget_ms);

// Connects (blocking -- decide has no urgency events.sock has), sends
// `line`, shuts down the write side, then waits for a one-line reply or
// for term_pid to exit, whichever happens first. No timeout of our own:
// the PermissionRequest hook entry's own timeout is the only cap.
// Returns nullopt for anything that isn't a clean single-line reply: no
// listener, the agent exiting first, EOF before a newline, or a reply
// over 64 KiB.
std::optional<std::string> wait_for_decision(const std::string& sock_path, const std::string& line,
                                              std::optional<pid_t> term_pid);

}  // namespace hook
