#include "envelope.hpp"

#include <cstdio>
#include <string_view>
#include <vector>

namespace hook {
namespace {

// For strings we generate ourselves or read from the environment (term
// info): not yet valid JSON string content, so it needs real escaping.
// Captured payload scalars skip this -- they're raw already-escaped JSON
// string tokens straight from a payload scan() already validated as JSON,
// so wrapping them in quotes as-is reproduces the original escaping.
std::string json_escape(std::string_view s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\t': out += "\\t"; break;
            case '\r': out += "\\r"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

void add_raw(std::vector<std::string>& fields, const char* key, const std::optional<std::string>& v) {
    if (!v || v->empty()) return;
    fields.push_back(std::string("\"") + key + "\":\"" + *v + "\"");
}

void add_escaped(std::vector<std::string>& fields, const char* key, const std::optional<std::string>& v) {
    if (!v || v->empty()) return;
    fields.push_back(std::string("\"") + key + "\":\"" + json_escape(*v) + "\"");
}

std::string join(const std::vector<std::string>& fields) {
    std::string out = "{";
    for (size_t i = 0; i < fields.size(); ++i) {
        if (i) out += ',';
        out += fields[i];
    }
    out += '}';
    return out;
}

}  // namespace

std::string verb_for(const std::optional<std::string>& tool_name) {
    if (!tool_name) return "think";
    const std::string& t = *tool_name;
    if (t == "Edit" || t == "Write" || t == "MultiEdit" || t == "NotebookEdit") return "edit";
    if (t == "Read") return "read";
    if (t == "Grep" || t == "Glob") return "search";
    if (t == "Bash") return "run";
    return "think";
}

const std::optional<std::string>& path_for(const Scalars& scalars) {
    if (scalars.file_path) return scalars.file_path;
    if (scalars.notebook_path) return scalars.notebook_path;
    return scalars.path;
}

bool wants_decision(const Scalars& scalars) {
    return scalars.hook_event_name && *scalars.hook_event_name == "PermissionRequest";
}

std::optional<std::string> build_envelope(const ScanOutput& scan, const EnvelopeOptions& opts) {
    if (!scan.ok) return std::nullopt;
    if (!scan.scalars.session_id || scan.scalars.session_id->empty()) return std::nullopt;

    std::vector<std::string> term_fields;
    if (opts.term.pid) term_fields.push_back("\"pid\":" + std::to_string(*opts.term.pid));
    add_escaped(term_fields, "tty", opts.term.tty);
    add_escaped(term_fields, "program", opts.term.program);
    add_escaped(term_fields, "cmux_surface", opts.term.cmux_surface);
    add_escaped(term_fields, "cmux_workspace", opts.term.cmux_workspace);
    add_escaped(term_fields, "cmux_socket", opts.term.cmux_socket);
    add_escaped(term_fields, "cmux_cli", opts.term.cmux_cli);

    std::vector<std::string> fields;
    fields.push_back("\"v\":1");
    fields.push_back(std::string("\"client\":\"") + (opts.client == Client::claude ? "claude" : "codex") + "\"");
    add_raw(fields, "event", scan.scalars.hook_event_name);
    fields.push_back("\"verb\":\"" + verb_for(scan.scalars.tool_name) + "\"");
    add_raw(fields, "path", path_for(scan.scalars));
    if (opts.decide) fields.push_back("\"want\":\"decision\"");
    add_raw(fields, "agent", scan.scalars.session_id);
    add_raw(fields, "tool", scan.scalars.tool_name);
    add_raw(fields, "tool_use_id", scan.scalars.tool_use_id);
    add_raw(fields, "prompt_id", scan.scalars.prompt_id);
    add_raw(fields, "cwd", scan.scalars.cwd);
    add_raw(fields, "transcript", scan.scalars.transcript_path);
    fields.push_back("\"ts\":" + std::to_string(opts.ts_ms));
    fields.push_back("\"term\":" + join(term_fields));
    if (scan.trunc) fields.push_back("\"trunc\":true");
    fields.push_back("\"hook\":" + scan.hook_json);

    return join(fields);
}

}  // namespace hook
