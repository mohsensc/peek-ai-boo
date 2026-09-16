#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace hook {

// Scalars pulled out of the payload as raw string tokens (no unescaping,
// no length limit): callers that need the real path or session id want the
// full value even when the copy embedded in hook_json got cut.
struct Scalars {
    std::optional<std::string> hook_event_name;
    std::optional<std::string> session_id;
    std::optional<std::string> tool_name;
    std::optional<std::string> tool_use_id;
    std::optional<std::string> prompt_id;
    std::optional<std::string> cwd;
    std::optional<std::string> transcript_path;
    // Under tool_input. Precedence (file_path, then notebook_path, then
    // path) is the caller's call, not this scanner's.
    std::optional<std::string> file_path;
    std::optional<std::string> notebook_path;
    std::optional<std::string> path;
};

struct ScanOutput {
    // False for anything that isn't a top-level JSON object: an array, a
    // scalar, unparseable bytes, empty input.
    bool ok = false;
    // A string got cut, or hook_json was dropped for size, or a
    // tool_response value got replaced.
    bool trunc = false;
    // The payload with tool_response nulled out and long strings cut, or
    // the literal text "null" when the result is still over 256 KiB.
    // Only meaningful when ok is true.
    std::string hook_json;
    Scalars scalars;
};

// One pass over `input`. Never throws: malformed JSON just yields ok=false.
ScanOutput scan(std::string_view input);

}  // namespace hook
