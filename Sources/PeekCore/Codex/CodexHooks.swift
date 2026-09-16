import Foundation

/// `~/.codex/hooks.json` wants the same event/timeout/matcher shape as
/// Claude's settings.json, just its own file and no PermissionRequest (Codex
/// approvals aren't in v1). SessionEnd and Interrupt cap at 3s, Codex's max
/// for those two; everything else gets 5s.
public enum CodexHooks {
    public static let spec = HookSpec(
        client: .codex,
        configPath: ".codex/hooks.json",
        events: [
            HookEvent("SessionStart", timeout: 5),
            HookEvent("UserPromptSubmit", timeout: 5),
            HookEvent("PreToolUse", timeout: 5, matcher: "*"),
            HookEvent("PostToolUse", timeout: 5, matcher: "*"),
            HookEvent("SubagentStart", timeout: 5),
            HookEvent("SubagentStop", timeout: 5),
            HookEvent("Stop", timeout: 5),
            HookEvent("Interrupt", timeout: 3),
            HookEvent("SessionEnd", timeout: 3),
        ],
        afterChange: "Codex: run /hooks once to trust the new entries."
    )
}
