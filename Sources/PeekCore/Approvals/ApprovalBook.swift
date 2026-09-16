import Foundation

public struct PendingPrompt: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let key: SessionKey
    public let tool: String
    public let toolInput: JSONValue?
    public let ts: Int64
    /// ToolSummary, or the first question.
    public let summary: String
    /// AskUserQuestion only.
    public let questions: [Question]?
    /// The hook exited without an answer. The row says "answer in terminal".
    public var hookGone: Bool
}

/// Which Claude permission prompts are waiting on the notch, and when the
/// terminal got to one first. Pure bookkeeping: the caller owns the
/// connections and only replies to what `take` hands back.
public struct ApprovalBook: Sendable, Equatable {
    /// Oldest first.
    public private(set) var pending: [PendingPrompt] = []

    /// Per session, what's been applied that would close a prompt opened
    /// later with an earlier ts. Events and decide lines come in on
    /// different sockets, so the terminal's answer can beat its own prompt
    /// here. Kept so that arrival order never changes the outcome.
    private var seen: [SessionKey: Seen] = [:]

    private struct Seen: Sendable, Equatable {
        var lastSessionEvent = Int64.min
        /// PostToolUse(Failure) newer than lastSessionEvent. Anything older
        /// can't matter: a prompt it would close is closed by that event too.
        var posts: [Post] = []
    }

    private struct Post: Sendable, Equatable {
        let tool: String?
        let input: JSONValue?
        let ts: Int64
    }

    /// Each PreToolUse empties the list, so it only grows across parallel
    /// calls. The cap is for a stream that never sends one.
    static let postMemory = 32

    private static let sessionEvents: Set<String> = [
        "PreToolUse", "PermissionDenied", "UserPromptSubmit", "Stop", "SessionEnd",
    ]
    private static let postEvents: Set<String> = ["PostToolUse", "PostToolUseFailure"]

    public init() {}

    /// Claude PermissionRequest with a tool, else nil. Also nil when there's
    /// nothing safe to show: `hook` was dropped for size, or it's a question
    /// we can't draw. Those stay with the terminal.
    public mutating func open(_ e: Event) -> PendingPrompt? {
        guard e.client == .claude, e.event == "PermissionRequest", e.wantsDecision,
              let tool = e.tool, !tool.isEmpty,
              let input = e.toolInput
        else { return nil }

        var questions: [Question]?
        if tool == "AskUserQuestion" {
            guard let parsed = Question.parse(input) else { return nil }
            questions = parsed
        }

        if let s = seen[e.key] {
            if s.lastSessionEvent > e.ts { return nil }
            if s.posts.contains(where: { $0.ts > e.ts && $0.tool == tool && $0.input == input }) {
                return nil
            }
        }

        let summary = questions?.first?.question
            ?? ToolSummary.make(tool: tool, input: input, cwd: e.cwd)
            ?? tool
        let prompt = PendingPrompt(
            id: UUID(), key: e.key, tool: tool, toolInput: input, ts: e.ts,
            summary: summary, questions: questions, hookGone: false
        )
        pending.append(prompt)
        return prompt
    }

    /// Prompts this event resolves, already removed from `pending`.
    public mutating func apply(_ e: Event) -> [PendingPrompt] {
        guard e.client == .claude else { return [] }
        let isSessionEvent = Self.sessionEvents.contains(e.event)
        let isPost = Self.postEvents.contains(e.event)
        guard isSessionEvent || isPost else { return [] }

        var s = seen[e.key] ?? Seen()
        if isSessionEvent {
            s.lastSessionEvent = max(s.lastSessionEvent, e.ts)
            s.posts.removeAll { $0.ts <= s.lastSessionEvent }
        } else if e.ts > s.lastSessionEvent {
            s.posts.append(Post(tool: e.tool, input: e.toolInput, ts: e.ts))
            if s.posts.count > Self.postMemory { s.posts.removeFirst() }
        }
        seen[e.key] = s

        let input = e.toolInput
        let resolves: (PendingPrompt) -> Bool = { p in
            guard p.key == e.key, e.ts > p.ts else { return false }
            return isSessionEvent || (e.tool == p.tool && input == p.toolInput)
        }
        let resolved = pending.filter(resolves)
        pending.removeAll(where: resolves)
        return resolved
    }

    /// Removes and returns the prompt so the caller can reply to it. nil if
    /// it's already resolved, or the hook is gone and nobody would read it.
    public mutating func take(_ id: UUID) -> PendingPrompt? {
        guard let i = pending.firstIndex(where: { $0.id == id }), !pending[i].hookGone else {
            return nil
        }
        return pending.remove(at: i)
    }

    /// Stays pending until an event resolves it; only the buttons go.
    public mutating func hookGone(_ id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].hookGone = true
    }

    func rememberedPosts(_ key: SessionKey) -> Int {
        seen[key]?.posts.count ?? 0
    }
}
