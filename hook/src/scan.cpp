#include "scan.hpp"

#include <cstddef>

namespace hook {
namespace {

constexpr size_t kCutAt = 4096;          // raw bytes between the quotes
constexpr size_t kHookCap = 256 * 1024;  // hook_json dropped past this

// Everything the recursive descent needs, threaded through one call chain
// instead of member state, so skip_value (tool_response) and the normal
// path share the exact same grammar with nothing but the discard flag
// differing.
struct Scanner {
    std::string_view in;
    size_t pos = 0;
    std::string out;
    bool ok = true;
    bool trunc = false;

    bool eof() const { return pos >= in.size(); }
    char peek() const { return in[pos]; }

    void fail() { ok = false; }

    void skip_ws() {
        while (!eof() && (in[pos] == ' ' || in[pos] == '\t' || in[pos] == '\n' || in[pos] == '\r')) {
            ++pos;
        }
    }

    // Position right after the closing, unescaped quote of the string that
    // starts at `pos` (which must be '"'), or npos if it never closes or an
    // escape runs off the end. Doesn't validate \u hex digits beyond
    // presence: a malformed \u sequence still has a definite length here,
    // and decide.cpp/envelope.cpp never decode these bytes anyway.
    size_t string_end(size_t start) const {
        size_t i = start + 1;
        while (i < in.size()) {
            const unsigned char c = static_cast<unsigned char>(in[i]);
            if (c == '"') return i + 1;
            if (c == '\\') {
                if (i + 1 >= in.size()) return std::string_view::npos;
                i += (in[i + 1] == 'u') ? 6 : 2;
                continue;
            }
            ++i;
        }
        return std::string_view::npos;
    }

    // Length in bytes of the escape or UTF-8 sequence starting at `i`
    // (which is inside [content_start, content_end)). Used only to find a
    // cut point that never lands mid-sequence.
    size_t token_len(size_t i, size_t content_end) const {
        const unsigned char c = static_cast<unsigned char>(in[i]);
        if (c == '\\') {
            if (i + 1 < content_end && in[i + 1] == 'u') return 6;
            return 2;
        }
        size_t len = 1;
        if ((c & 0xE0) == 0xC0) len = 2;
        else if ((c & 0xF0) == 0xE0) len = 3;
        else if ((c & 0xF8) == 0xF0) len = 4;
        if (i + len > content_end) len = content_end - i;  // malformed tail, don't overrun
        return len;
    }

    // Parses the string at `pos`, appends it (cut if needed) to `out`
    // unless `discard`, and hands the full raw content back via `capture`
    // when given. Advances pos past the closing quote either way.
    void copy_string(bool discard, std::optional<std::string>* capture) {
        const size_t start = pos;
        const size_t end = string_end(start);
        if (end == std::string_view::npos) { fail(); pos = in.size(); return; }
        const size_t content_start = start + 1;
        const size_t content_end = end - 1;
        const size_t len = content_end - content_start;

        if (capture) *capture = std::string(in.substr(content_start, len));

        if (!discard) {
            if (len <= kCutAt) {
                out.append(in.substr(start, end - start));
            } else {
                size_t i = content_start;
                size_t last_safe = content_start;
                while (i < content_end) {
                    const size_t tok = token_len(i, content_end);
                    const size_t prefix = (i + tok) - content_start;
                    if (prefix > kCutAt) break;
                    i += tok;
                    last_safe = i;
                }
                out += '"';
                out.append(in.substr(content_start, last_safe - content_start));
                out += "\xE2\x80\xA6";  // U+2026 HORIZONTAL ELLIPSIS, raw bytes
                out += '"';
                trunc = true;
            }
        }
        pos = end;
    }

    void copy_literal_or_number(bool discard) {
        static constexpr std::string_view kTrue = "true";
        static constexpr std::string_view kFalse = "false";
        static constexpr std::string_view kNull = "null";
        for (auto lit : {kTrue, kFalse, kNull}) {
            if (in.substr(pos, lit.size()) == lit) {
                if (!discard) out.append(lit);
                pos += lit.size();
                return;
            }
        }
        const size_t start = pos;
        if (!eof() && in[pos] == '-') ++pos;
        const size_t digits_start = pos;
        while (!eof() && in[pos] >= '0' && in[pos] <= '9') ++pos;
        if (pos == digits_start) { fail(); return; }
        if (!eof() && in[pos] == '.') {
            ++pos;
            const size_t frac_start = pos;
            while (!eof() && in[pos] >= '0' && in[pos] <= '9') ++pos;
            if (pos == frac_start) { fail(); return; }
        }
        if (!eof() && (in[pos] == 'e' || in[pos] == 'E')) {
            ++pos;
            if (!eof() && (in[pos] == '+' || in[pos] == '-')) ++pos;
            const size_t exp_start = pos;
            while (!eof() && in[pos] >= '0' && in[pos] <= '9') ++pos;
            if (pos == exp_start) { fail(); return; }
        }
        if (!discard) out.append(in.substr(start, pos - start));
    }

    void parse_value(bool discard) {
        if (!ok || eof()) { fail(); return; }
        switch (peek()) {
            case '"': copy_string(discard, nullptr); return;
            case '{': parse_object(discard, /*is_top=*/false, /*capture_tool_input=*/false); return;
            case '[': parse_array(discard); return;
            default: copy_literal_or_number(discard); return;
        }
    }

    void parse_array(bool discard) {
        if (!discard) out += '[';
        ++pos;  // '['
        skip_ws();
        if (!eof() && peek() == ']') {
            if (!discard) out += ']';
            ++pos;
            return;
        }
        for (;;) {
            skip_ws();
            parse_value(discard);
            if (!ok) return;
            skip_ws();
            if (eof()) { fail(); return; }
            if (peek() == ',') {
                if (!discard) out += ',';
                ++pos;
                continue;
            }
            if (peek() == ']') {
                if (!discard) out += ']';
                ++pos;
                return;
            }
            fail();
            return;
        }
    }

    std::optional<std::string>* named_scalar(Scalars& s, std::string_view key) {
        if (key == "hook_event_name") return &s.hook_event_name;
        if (key == "session_id") return &s.session_id;
        if (key == "tool_name") return &s.tool_name;
        if (key == "tool_use_id") return &s.tool_use_id;
        if (key == "prompt_id") return &s.prompt_id;
        if (key == "cwd") return &s.cwd;
        if (key == "transcript_path") return &s.transcript_path;
        return nullptr;
    }

    std::optional<std::string>* tool_input_field(Scalars& s, std::string_view key) {
        if (key == "file_path") return &s.file_path;
        if (key == "notebook_path") return &s.notebook_path;
        if (key == "path") return &s.path;
        return nullptr;
    }

    void parse_object(bool discard, bool is_top, bool capture_tool_input, Scalars* scalars = nullptr) {
        if (!discard) out += '{';
        ++pos;  // '{'
        skip_ws();
        if (!eof() && peek() == '}') {
            if (!discard) out += '}';
            ++pos;
            return;
        }
        for (;;) {
            skip_ws();
            if (eof() || peek() != '"') { fail(); return; }
            const size_t key_start = pos;
            const size_t key_end = string_end(key_start);
            if (key_end == std::string_view::npos) { fail(); return; }
            const std::string_view key = in.substr(key_start + 1, key_end - key_start - 2);
            if (!discard) out.append(in.substr(key_start, key_end - key_start));
            pos = key_end;

            skip_ws();
            if (eof() || peek() != ':') { fail(); return; }
            if (!discard) out += ':';
            ++pos;
            skip_ws();
            if (eof()) { fail(); return; }

            if (is_top && key == "tool_response") {
                parse_value(/*discard=*/true);
                if (!ok) return;
                if (!discard) out += "null";
                trunc = true;
            } else if (is_top && scalars != nullptr && named_scalar(*scalars, key) != nullptr) {
                if (peek() == '"') {
                    copy_string(discard, named_scalar(*scalars, key));
                } else {
                    parse_value(discard);
                }
            } else if (is_top && key == "tool_input" && !eof() && peek() == '{') {
                parse_object(discard, /*is_top=*/false, /*capture_tool_input=*/true, scalars);
            } else if (capture_tool_input && scalars != nullptr && tool_input_field(*scalars, key) != nullptr) {
                if (peek() == '"') {
                    copy_string(discard, tool_input_field(*scalars, key));
                } else {
                    parse_value(discard);
                }
            } else {
                parse_value(discard);
            }
            if (!ok) return;

            skip_ws();
            if (eof()) { fail(); return; }
            if (peek() == ',') {
                if (!discard) out += ',';
                ++pos;
                continue;
            }
            if (peek() == '}') {
                if (!discard) out += '}';
                ++pos;
                return;
            }
            fail();
            return;
        }
    }
};

}  // namespace

ScanOutput scan(std::string_view input) {
    ScanOutput result;
    Scanner s;
    s.in = input;
    s.skip_ws();
    if (s.eof() || s.peek() != '{') {
        return result;  // ok stays false: not an object
    }
    s.parse_object(/*discard=*/false, /*is_top=*/true, /*capture_tool_input=*/false, &result.scalars);
    if (s.ok) {
        s.skip_ws();
        if (!s.eof()) s.fail();  // trailing garbage after the object
    }
    if (!s.ok) return result;  // ok stays false

    result.ok = true;
    result.trunc = s.trunc;
    if (s.out.size() > kHookCap) {
        result.hook_json = "null";
        result.trunc = true;
    } else {
        result.hook_json = std::move(s.out);
    }
    return result;
}

}  // namespace hook
