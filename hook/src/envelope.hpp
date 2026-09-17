#pragma once

#include <cstdint>
#include <optional>
#include <string>

#include "scan.hpp"
#include "term.hpp"

namespace hook {

enum class Client { claude, codex };

// "edit"/"read"/"search"/"run", else "think". tool_name absent counts as
// "think" too -- there's no tool to name a verb after.
std::string verb_for(const std::optional<std::string>& tool_name);

// tool_input.file_path, else notebook_path, else path.
const std::optional<std::string>& path_for(const Scalars& scalars);

// The only event the hook ever blocks on.
bool wants_decision(const Scalars& scalars);

struct EnvelopeOptions {
    Client client;
    int64_t ts_ms;
    Term term;
    bool decide = false;  // true adds "want":"decision", for decide.sock
};

// The line to send, or nullopt for the two cases the hook sends nothing
// for: the payload wasn't a JSON object, or it had no session_id.
std::optional<std::string> build_envelope(const ScanOutput& scan, const EnvelopeOptions& opts);

}  // namespace hook
