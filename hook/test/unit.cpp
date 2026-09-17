// Plain asserts, no framework: check() records pass/fail and prints
// "hook unit: N passed" once everything ran clean. Anything short of that
// is a bug scripts/checks/hook.sh needs to catch, not smooth over.
#include "../src/decide.hpp"
#include "../src/envelope.hpp"
#include "../src/scan.hpp"
#include "../src/term.hpp"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

namespace {

int g_passed = 0;
int g_failed = 0;

void check(bool cond, const std::string& name) {
    if (cond) {
        ++g_passed;
    } else {
        ++g_failed;
        std::fprintf(stderr, "FAIL %s\n", name.c_str());
    }
}

// Finds `"key":"..."` and returns the raw bytes between the quotes,
// stopping at the first unescaped closing quote. Good enough for these
// tests: none of the crafted values contain unescaped quotes of their own.
std::string extract_raw(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\":\"";
    const auto start = json.find(needle);
    if (start == std::string::npos) return "\x01NOTFOUND";
    size_t i = start + needle.size();
    while (i < json.size()) {
        if (json[i] == '"') return json.substr(start + needle.size(), i - (start + needle.size()));
        if (json[i] == '\\') { i += 2; continue; }
        ++i;
    }
    return "\x01UNTERMINATED";
}

// scan

void test_scan_tool_response_becomes_null() {
    const std::string big(1024 * 1024, 'x');
    const std::string input = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\",\"tool_response\":\"" +
                               big + "\"}";
    const auto r = hook::scan(input);
    check(r.ok, "tool_response.ok");
    // tool_response always gets replaced, even when -- as here -- it isn't
    // the reason hook_json ends up over the 256 KiB cap: that's still a
    // cut, and trunc says so.
    check(r.trunc, "tool_response.sets_trunc");
    check(r.hook_json.find("\"tool_response\":null") != std::string::npos, "tool_response.nulled");
    check(r.hook_json.size() < 1000, "tool_response.small_output");
    check(r.scalars.session_id && *r.scalars.session_id == "s1", "tool_response.session_id_still_captured");
    check(r.scalars.hook_event_name && *r.scalars.hook_event_name == "PreToolUse",
          "tool_response.event_still_captured");
}

void test_scan_ascii_string_cut_at_4096() {
    const std::string big(10 * 1024, 'A');
    const std::string input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\",\"big\":\"" + big + "\"}";
    const auto r = hook::scan(input);
    check(r.ok, "ascii_cut.ok");
    check(r.trunc, "ascii_cut.trunc");
    const std::string got = extract_raw(r.hook_json, "big");
    check(got.size() == 4096 + 3, "ascii_cut.length_4099, got=" + std::to_string(got.size()));
    check(got.substr(0, 4096) == std::string(4096, 'A'), "ascii_cut.prefix_is_a");
    check(got.substr(4096) == "\xE2\x80\xA6", "ascii_cut.ellipsis_suffix");
}

void test_scan_emoji_cut_on_boundary() {
    std::string emoji;
    for (int i = 0; i < 2000; ++i) emoji += "\xF0\x9F\x98\x80";  // U+1F600, 4 bytes each
    const std::string input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\",\"em\":\"" + emoji + "\"}";
    const auto r = hook::scan(input);
    const std::string got = extract_raw(r.hook_json, "em");
    check(got.size() > 3, "emoji_cut.has_content");
    const size_t raw_len = got.size() - 3;  // minus the ellipsis
    check(raw_len % 4 == 0, "emoji_cut.multiple_of_4, got=" + std::to_string(raw_len));
    check(raw_len <= 4096, "emoji_cut.under_cap");
    check(got.substr(got.size() - 3) == "\xE2\x80\xA6", "emoji_cut.ellipsis_suffix");
}

void test_scan_never_splits_two_byte_utf8_or_escapes() {
    std::string accented;
    for (int i = 0; i < 3000; ++i) accented += "\xC3\xA9";  // U+00E9 'é', 2 bytes each
    std::string input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\",\"ac\":\"" + accented + "\"}";
    auto r = hook::scan(input);
    std::string got = extract_raw(r.hook_json, "ac");
    check((got.size() - 3) % 2 == 0, "utf8_boundary.even_length, got=" + std::to_string(got.size() - 3));

    std::string escapes;
    for (int i = 0; i < 3000; ++i) escapes += "\\\"";  // literal backslash-quote pairs, 2 raw bytes each
    input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\",\"es\":\"" + escapes + "\"}";
    r = hook::scan(input);
    got = extract_raw(r.hook_json, "es");
    // extract_raw itself walks escapes correctly, so an odd length here
    // would mean a cut landed mid-escape and the closing quote drifted.
    check((got.size() - 3) % 2 == 0, "escape_boundary.even_length, got=" + std::to_string(got.size() - 3));
    check(got.substr(0, 2) == "\\\"", "escape_boundary.starts_whole");
}

void test_scan_nested_strings_cut() {
    const std::string big(9000, 'z');
    const std::string input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\",\"arr\":[\"short\",\"" + big +
                               "\"],\"obj\":{\"deep\":{\"v\":\"" + big + "\"}}}";
    const auto r = hook::scan(input);
    check(r.ok, "nested_cut.ok");
    check(r.trunc, "nested_cut.trunc");
    // Both occurrences of the big string got cut: neither survives at full
    // length anywhere in the output.
    check(r.hook_json.find(big) == std::string::npos, "nested_cut.no_full_copy_survives");
}

void test_scan_256kib_drop() {
    std::string input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\"";
    const std::string chunk(4096, 'q');
    for (int i = 0; i < 100; ++i) {
        input += ",\"k" + std::to_string(i) + "\":\"" + chunk + "\"";
    }
    input += "}";
    const auto r = hook::scan(input);
    check(r.ok, "drop_256kib.ok");
    check(r.trunc, "drop_256kib.trunc");
    check(r.hook_json == "null", "drop_256kib.hook_is_null, got_size=" + std::to_string(r.hook_json.size()));
}

void test_scan_rejects_non_object_and_broken_json() {
    check(!hook::scan("[1,2,3]").ok, "non_object.array");
    check(!hook::scan("\"just a string\"").ok, "non_object.string");
    check(!hook::scan("").ok, "non_object.empty");
    check(!hook::scan("not json").ok, "broken.garbage");
    check(!hook::scan("{").ok, "broken.unterminated_object");
    check(!hook::scan("{\"a\":}").ok, "broken.missing_value");
    check(!hook::scan("{\"a\":1,}").ok, "broken.trailing_comma");
    check(!hook::scan("{\"a\":1}garbage").ok, "broken.trailing_garbage");
}

void test_scan_captures_scalars_even_with_huge_tool_response() {
    const std::string big(500 * 1024, 'y');
    const std::string input = "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"sess9\",\"tool_name\":\"Bash\","
                               "\"tool_use_id\":\"tu1\",\"prompt_id\":\"p1\",\"cwd\":\"/a/b\","
                               "\"transcript_path\":\"/t.jsonl\",\"tool_response\":\"" +
                               big + "\"}";
    const auto r = hook::scan(input);
    check(r.ok, "scalars.ok");
    check(r.scalars.hook_event_name && *r.scalars.hook_event_name == "PreToolUse", "scalars.event");
    check(r.scalars.session_id && *r.scalars.session_id == "sess9", "scalars.session_id");
    check(r.scalars.tool_name && *r.scalars.tool_name == "Bash", "scalars.tool_name");
    check(r.scalars.tool_use_id && *r.scalars.tool_use_id == "tu1", "scalars.tool_use_id");
    check(r.scalars.prompt_id && *r.scalars.prompt_id == "p1", "scalars.prompt_id");
    check(r.scalars.cwd && *r.scalars.cwd == "/a/b", "scalars.cwd");
    check(r.scalars.transcript_path && *r.scalars.transcript_path == "/t.jsonl", "scalars.transcript_path");
    check(r.hook_json.size() < 1000, "scalars.tool_response_still_dropped");
}

void test_scan_path_precedence() {
    auto file_path_of = [](const std::string& tool_input_body) {
        const std::string input =
            "{\"session_id\":\"s\",\"hook_event_name\":\"e\",\"tool_input\":{" + tool_input_body + "}}";
        return hook::scan(input).scalars;
    };
    {
        const auto s = file_path_of("\"file_path\":\"F\",\"notebook_path\":\"N\",\"path\":\"P\"");
        check(hook::path_for(s) && *hook::path_for(s) == "F", "path_precedence.file_wins");
    }
    {
        const auto s = file_path_of("\"notebook_path\":\"N\",\"path\":\"P\"");
        check(hook::path_for(s) && *hook::path_for(s) == "N", "path_precedence.notebook_next");
    }
    {
        const auto s = file_path_of("\"path\":\"P\"");
        check(hook::path_for(s) && *hook::path_for(s) == "P", "path_precedence.path_last");
    }
    {
        const auto s = file_path_of("");
        check(!hook::path_for(s), "path_precedence.none_means_nullopt");
    }
}

void test_scan() {
    test_scan_tool_response_becomes_null();
    test_scan_ascii_string_cut_at_4096();
    test_scan_emoji_cut_on_boundary();
    test_scan_never_splits_two_byte_utf8_or_escapes();
    test_scan_nested_strings_cut();
    test_scan_256kib_drop();
    test_scan_rejects_non_object_and_broken_json();
    test_scan_captures_scalars_even_with_huge_tool_response();
    test_scan_path_precedence();
}

// envelope

void test_verb_table() {
    using hook::verb_for;
    check(verb_for(std::string("Edit")) == "edit", "verb.edit");
    check(verb_for(std::string("Write")) == "edit", "verb.write");
    check(verb_for(std::string("MultiEdit")) == "edit", "verb.multiedit");
    check(verb_for(std::string("NotebookEdit")) == "edit", "verb.notebookedit");
    check(verb_for(std::string("Read")) == "read", "verb.read");
    check(verb_for(std::string("Grep")) == "search", "verb.grep");
    check(verb_for(std::string("Glob")) == "search", "verb.glob");
    check(verb_for(std::string("Bash")) == "run", "verb.bash");
    check(verb_for(std::string("Task")) == "think", "verb.other_is_think");
    check(verb_for(std::nullopt) == "think", "verb.absent_is_think");
}

void test_wants_decision() {
    hook::Scalars s;
    s.hook_event_name = "PermissionRequest";
    check(hook::wants_decision(s), "wants_decision.permission_request");
    s.hook_event_name = "PreToolUse";
    check(!hook::wants_decision(s), "wants_decision.other_event");
    s.hook_event_name.reset();
    check(!hook::wants_decision(s), "wants_decision.no_event");
}

void test_envelope_field_omission() {
    hook::ScanOutput scan;
    scan.ok = true;
    scan.hook_json = "{}";
    scan.scalars.session_id = "sess1";
    hook::EnvelopeOptions opts;
    opts.client = hook::Client::claude;
    opts.ts_ms = 123;
    opts.decide = false;
    const auto line = hook::build_envelope(scan, opts);
    check(line.has_value(), "omission.line_built");
    if (!line) return;
    check(line->rfind("{\"v\":1", 0) == 0, "omission.v_first");
    check(line->find("\"tool\":") == std::string::npos, "omission.no_tool_when_absent");
    check(line->find("\"cwd\":") == std::string::npos, "omission.no_cwd_when_absent");
    check(line->find("\"trunc\":") == std::string::npos, "omission.no_trunc_when_false");
    check(line->find("\"want\":") == std::string::npos, "omission.no_want_when_not_decide");
    check(line->find("\"agent\":\"sess1\"") != std::string::npos, "omission.agent_present");
    check(line->find("\"hook\":{}") != std::string::npos, "omission.hook_present");

    scan.trunc = true;
    scan.scalars.tool_name = "Bash";
    scan.scalars.cwd = "";  // empty string: still omitted
    opts.decide = true;
    const auto line2 = hook::build_envelope(scan, opts);
    check(line2.has_value(), "omission.line2_built");
    if (!line2) return;
    check(line2->find("\"trunc\":true") != std::string::npos, "omission.trunc_present_when_true");
    check(line2->find("\"tool\":\"Bash\"") != std::string::npos, "omission.tool_present");
    check(line2->find("\"cwd\":") == std::string::npos, "omission.empty_string_omitted");
    check(line2->find("\"want\":\"decision\"") != std::string::npos, "omission.want_present_when_decide");
}

void test_envelope_sends_nothing_for_bad_input() {
    hook::EnvelopeOptions opts;
    opts.client = hook::Client::claude;
    opts.ts_ms = 1;

    hook::ScanOutput not_object;
    not_object.ok = false;
    check(!hook::build_envelope(not_object, opts).has_value(), "no_send.not_object");

    hook::ScanOutput no_session;
    no_session.ok = true;
    no_session.hook_json = "{}";
    check(!hook::build_envelope(no_session, opts).has_value(), "no_send.no_session_id");

    hook::ScanOutput empty_session;
    empty_session.ok = true;
    empty_session.hook_json = "{}";
    empty_session.scalars.session_id = "";
    check(!hook::build_envelope(empty_session, opts).has_value(), "no_send.empty_session_id");
}

void test_envelope_hook_is_json_null_on_drop() {
    // End to end: a payload that actually trips the 256 KiB cap, spliced
    // through build_envelope. scan.hook_json is the raw text "null" (4
    // bytes, unquoted) -- build_envelope must splice it as the JSON literal
    // null, not as the string "null", or Event.parse gets a wrong type.
    std::string input = "{\"session_id\":\"s\",\"hook_event_name\":\"e\"";
    const std::string chunk(4096, 'q');
    for (int i = 0; i < 100; ++i) input += ",\"k" + std::to_string(i) + "\":\"" + chunk + "\"";
    input += "}";
    const auto scan = hook::scan(input);
    check(scan.hook_json == "null", "hook_null.scan_dropped");

    hook::EnvelopeOptions opts;
    opts.client = hook::Client::claude;
    opts.ts_ms = 1;
    const auto line = hook::build_envelope(scan, opts);
    check(line.has_value(), "hook_null.line_built");
    if (!line) return;
    check(line->find("\"hook\":null") != std::string::npos, "hook_null.unquoted_literal, line=" + *line);
    check(line->find("\"hook\":\"null\"") == std::string::npos, "hook_null.not_a_string");
}

void test_envelope() {
    test_verb_table();
    test_wants_decision();
    test_envelope_field_omission();
    test_envelope_sends_nothing_for_bad_input();
    test_envelope_hook_is_json_null_on_drop();
}

// term

void test_term_walk_skips_shells() {
    std::map<pid_t, hook::ProcEntry> procs;
    procs[500] = {500, 400, "zsh", static_cast<dev_t>(-1)};
    procs[400] = {400, 300, "bash", static_cast<dev_t>(-1)};
    procs[300] = {300, 200, "node", 7};
    procs[200] = {200, 1, "launchd", static_cast<dev_t>(-1)};

    auto lookup = [&](pid_t pid) -> std::optional<hook::ProcEntry> {
        const auto it = procs.find(pid);
        if (it == procs.end()) return std::nullopt;
        return it->second;
    };

    const auto found = hook::walk_to_agent(500, lookup);
    check(found.has_value(), "term_walk.found");
    check(found && found->pid == 300, "term_walk.skipped_two_shells");
}

void test_term_walk_stops_before_pid1() {
    std::map<pid_t, hook::ProcEntry> procs;
    procs[50] = {50, 20, "sh", static_cast<dev_t>(-1)};
    procs[20] = {20, 1, "bash", static_cast<dev_t>(-1)};

    auto lookup = [&](pid_t pid) -> std::optional<hook::ProcEntry> {
        const auto it = procs.find(pid);
        if (it == procs.end()) return std::nullopt;
        return it->second;
    };

    check(!hook::walk_to_agent(50, lookup).has_value(), "term_walk.stops_before_pid1");
}

void test_term_walk_non_shell_start() {
    std::map<pid_t, hook::ProcEntry> procs;
    procs[900] = {900, 1, "Ghostty", static_cast<dev_t>(-1)};
    auto lookup = [&](pid_t pid) -> std::optional<hook::ProcEntry> {
        const auto it = procs.find(pid);
        if (it == procs.end()) return std::nullopt;
        return it->second;
    };
    const auto found = hook::walk_to_agent(900, lookup);
    check(found && found->pid == 900, "term_walk.non_shell_returned_immediately");
}

void test_term_walk_missing_ancestor() {
    auto lookup = [&](pid_t) -> std::optional<hook::ProcEntry> { return std::nullopt; };
    check(!hook::walk_to_agent(42, lookup).has_value(), "term_walk.missing_lookup_is_nullopt");
}

void test_tty_path_nodev() {
    check(!hook::tty_path(static_cast<dev_t>(-1)).has_value(), "tty_path.nodev_is_nullopt");
    check(!hook::tty_path(99999999).has_value(), "tty_path.bogus_device_is_nullopt");
}

void test_term() {
    test_term_walk_skips_shells();
    test_term_walk_stops_before_pid1();
    test_term_walk_non_shell_start();
    test_term_walk_missing_ancestor();
    test_tty_path_nodev();
}

// decide

void test_decide_allow() {
    const auto r = hook::parse_reply(R"({"decision":"allow"})");
    check(r.decision == hook::Decision::allow, "decide.allow_decoded");
    const auto out = hook::hook_output(r);
    check(out.has_value(), "decide.allow_has_output");
    check(out && *out ==
              R"({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})",
          "decide.allow_output_shape");
}

void test_decide_deny_with_tricky_message() {
    // quotes, a backslash, a newline, and a non-ASCII character, escaped
    // exactly the way a JSON encoder would.
    const std::string reply = "{\"decision\":\"deny\",\"message\":\"has \\\"quotes\\\" and \\\\ and \\nline "
                               "and \xc3\xa9\"}";
    const auto r = hook::parse_reply(reply);
    check(r.decision == hook::Decision::deny, "decide.deny_decoded");
    const std::string expected_token =
        "\"has \\\"quotes\\\" and \\\\ and \\nline and \xc3\xa9\"";
    check(r.message_token == expected_token, "decide.message_copied_raw");
    const auto out = hook::hook_output(r);
    check(out.has_value(), "decide.deny_has_output");
    if (out) {
        check(out->find(expected_token) != std::string::npos, "decide.deny_output_carries_message_raw");
    }
}

void test_decide_bare_deny() {
    const auto r = hook::parse_reply(R"({"decision":"deny"})");
    check(r.decision == hook::Decision::deny, "decide.bare_deny_decoded");
    check(r.message_token.empty(), "decide.bare_deny_no_token");
    const auto out = hook::hook_output(r);
    check(out && out->find("\"message\":\"Denied from peek-ai-boo.\"") != std::string::npos,
          "decide.bare_deny_default_message");
}

void test_decide_silent_cases() {
    check(hook::parse_reply(R"({"decision":"maybe"})").decision == hook::Decision::silent, "decide.silent_maybe");
    check(hook::parse_reply("garbage not json").decision == hook::Decision::silent, "decide.silent_garbage");
    check(hook::parse_reply("").decision == hook::Decision::silent, "decide.silent_empty");
    check(hook::parse_reply("{").decision == hook::Decision::silent, "decide.silent_unterminated");
    check(hook::parse_reply("[1,2,3]").decision == hook::Decision::silent, "decide.silent_not_object");
    const std::string huge = "{\"decision\":\"deny\",\"message\":\"" + std::string(70 * 1024, 'a') + "\"}";
    // parse_reply itself doesn't enforce the 64 KiB cap (sock.cpp does,
    // before a line this big would ever reach here), but it must still
    // parse or fail cleanly rather than hang or crash.
    const auto r = hook::parse_reply(huge);
    check(r.decision == hook::Decision::deny, "decide.oversized_still_parses_here");

    check(!hook::hook_output(hook::DecideReply{}).has_value(), "decide.silent_has_no_output");
}

void test_decide() {
    test_decide_allow();
    test_decide_deny_with_tricky_message();
    test_decide_bare_deny();
    test_decide_silent_cases();
}

}  // namespace

int main() {
    test_scan();
    test_envelope();
    test_term();
    test_decide();

    if (g_failed > 0) {
        std::fprintf(stderr, "hook unit: %d passed, %d FAILED\n", g_passed, g_failed);
        return 1;
    }
    std::printf("hook unit: %d passed\n", g_passed);
    return 0;
}
