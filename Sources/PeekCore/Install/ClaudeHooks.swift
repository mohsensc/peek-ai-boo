import Foundation

/// Claude Code's hook table. See docs/design.md's Install section for why
/// these 12 events and these two timeouts.
public enum ClaudeHooks {
    public static let spec = HookSpec(
        client: .claude,
        configPath: ".claude/settings.json",
        events: [
            HookEvent("SessionStart", timeout: 5),
            HookEvent("UserPromptSubmit", timeout: 5),
            HookEvent("PreToolUse", timeout: 5, matcher: "*"),
            HookEvent("PostToolUse", timeout: 5, matcher: "*"),
            HookEvent("PostToolUseFailure", timeout: 5, matcher: "*"),
            HookEvent("PermissionRequest", timeout: 3600, matcher: "*"),
            HookEvent("PermissionDenied", timeout: 5, matcher: "*"),
            HookEvent("Notification", timeout: 5),
            HookEvent("Stop", timeout: 5),
            HookEvent("SubagentStart", timeout: 5),
            HookEvent("SubagentStop", timeout: 5),
            HookEvent("SessionEnd", timeout: 5),
        ]
    )
}
