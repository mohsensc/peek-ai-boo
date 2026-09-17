#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace hook {

enum class Decision { allow, deny, silent };

struct DecideReply {
    Decision decision = Decision::silent;
    // Raw JSON string token for a deny message, quotes included, copied
    // byte for byte from the reply. Empty means no usable message: either
    // none was sent, or it wasn't a string.
    std::string message_token;
};

// Anything that isn't {"decision":"allow"} or {"decision":"deny",...} --
// garbage, a bare array, {"decision":"maybe"}, unterminated JSON -- comes
// back Decision::silent. Never throws.
DecideReply parse_reply(std::string_view line);

// The one stdout line for a PermissionRequest reply, or nullopt for a
// silent one (nothing gets printed).
std::optional<std::string> hook_output(const DecideReply& reply);

}  // namespace hook
