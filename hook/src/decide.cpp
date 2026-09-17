#include "decide.hpp"

#include <array>

namespace hook {
namespace {

// A tiny, dedicated JSON reader for reply lines. Anything on this machine
// can write to decide.sock, so this never trusts the shape and only ever
// fails closed (ok=false, which parse_reply turns into Decision::silent).
struct Reader {
    std::string_view in;
    size_t pos = 0;
    bool ok = true;

    bool eof() const { return pos >= in.size(); }
    char peek() const { return in[pos]; }

    void skip_ws() {
        while (!eof() && (peek() == ' ' || peek() == '\t' || peek() == '\n' || peek() == '\r')) ++pos;
    }

    // Content between the quotes, no unescape. Advances past the closing
    // quote. Sets ok=false and returns "" on anything unterminated.
    std::string_view read_string() {
        if (eof() || peek() != '"') { ok = false; return {}; }
        size_t i = pos + 1;
        while (i < in.size()) {
            const unsigned char c = static_cast<unsigned char>(in[i]);
            if (c == '"') {
                const std::string_view content = in.substr(pos + 1, i - (pos + 1));
                pos = i + 1;
                return content;
            }
            if (c == '\\') {
                if (i + 1 >= in.size()) { ok = false; return {}; }
                i += (in[i + 1] == 'u') ? 6 : 2;
                continue;
            }
            ++i;
        }
        ok = false;
        return {};
    }

    // The raw token including quotes, for a value that must be copied byte
    // for byte rather than reinterpreted.
    std::string_view read_string_token() {
        const size_t start = pos;
        read_string();
        if (!ok) return {};
        return in.substr(start, pos - start);
    }

    void skip_value() {
        if (!ok || eof()) { ok = false; return; }
        switch (peek()) {
            case '"': read_string(); return;
            case '{': skip_object(); return;
            case '[': skip_array(); return;
            default: skip_scalar(); return;
        }
    }

    void skip_object() {
        ++pos;
        skip_ws();
        if (!eof() && peek() == '}') { ++pos; return; }
        for (;;) {
            skip_ws();
            read_string();
            if (!ok) return;
            skip_ws();
            if (eof() || peek() != ':') { ok = false; return; }
            ++pos;
            skip_ws();
            skip_value();
            if (!ok) return;
            skip_ws();
            if (eof()) { ok = false; return; }
            if (peek() == ',') { ++pos; continue; }
            if (peek() == '}') { ++pos; return; }
            ok = false;
            return;
        }
    }

    void skip_array() {
        ++pos;
        skip_ws();
        if (!eof() && peek() == ']') { ++pos; return; }
        for (;;) {
            skip_ws();
            skip_value();
            if (!ok) return;
            skip_ws();
            if (eof()) { ok = false; return; }
            if (peek() == ',') { ++pos; continue; }
            if (peek() == ']') { ++pos; return; }
            ok = false;
            return;
        }
    }

    void skip_scalar() {
        static constexpr std::array<std::string_view, 3> kLits = {"true", "false", "null"};
        for (auto lit : kLits) {
            if (in.substr(pos, lit.size()) == lit) { pos += lit.size(); return; }
        }
        if (!eof() && peek() == '-') ++pos;
        const size_t digits = pos;
        while (!eof() && peek() >= '0' && peek() <= '9') ++pos;
        if (pos == digits) { ok = false; return; }
        if (!eof() && peek() == '.') {
            ++pos;
            const size_t frac = pos;
            while (!eof() && peek() >= '0' && peek() <= '9') ++pos;
            if (pos == frac) { ok = false; return; }
        }
        if (!eof() && (peek() == 'e' || peek() == 'E')) {
            ++pos;
            if (!eof() && (peek() == '+' || peek() == '-')) ++pos;
            const size_t exp = pos;
            while (!eof() && peek() >= '0' && peek() <= '9') ++pos;
            if (pos == exp) { ok = false; return; }
        }
    }
};

}  // namespace

DecideReply parse_reply(std::string_view line) {
    DecideReply result;  // defaults to silent

    Reader r{line};
    r.skip_ws();
    if (r.eof() || r.peek() != '{') return result;
    ++r.pos;
    r.skip_ws();

    std::optional<std::string> decision;
    std::string message_token;

    if (!r.eof() && r.peek() == '}') {
        ++r.pos;
    } else {
        for (;;) {
            r.skip_ws();
            const std::string_view key = r.read_string();
            if (!r.ok) return result;
            r.skip_ws();
            if (r.eof() || r.peek() != ':') return result;
            ++r.pos;
            r.skip_ws();
            if (r.eof()) return result;

            if (key == "decision" && r.peek() == '"') {
                const std::string_view v = r.read_string();
                if (!r.ok) return result;
                decision = std::string(v);
            } else if (key == "message" && r.peek() == '"') {
                const std::string_view tok = r.read_string_token();
                if (!r.ok) return result;
                message_token = std::string(tok);
            } else {
                r.skip_value();
                if (!r.ok) return result;
            }

            r.skip_ws();
            if (r.eof()) return result;
            if (r.peek() == ',') { ++r.pos; continue; }
            if (r.peek() == '}') { ++r.pos; break; }
            return result;
        }
    }
    r.skip_ws();
    if (!r.eof()) return result;  // trailing bytes after the object: bad reply

    if (!decision) return result;
    if (*decision == "allow") {
        result.decision = Decision::allow;
    } else if (*decision == "deny") {
        result.decision = Decision::deny;
        result.message_token = message_token;
    }
    return result;
}

std::optional<std::string> hook_output(const DecideReply& reply) {
    switch (reply.decision) {
        case Decision::allow:
            return std::string(
                R"({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})");
        case Decision::deny: {
            const std::string message = reply.message_token.empty() ? "\"Denied from peek-ai-boo.\"" : reply.message_token;
            return "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":"
                   "\"deny\",\"message\":" +
                   message + "}}}";
        }
        case Decision::silent:
        default:
            return std::nullopt;
    }
}

}  // namespace hook
