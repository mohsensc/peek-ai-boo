import Foundation

public enum SessionState: Sendable, Equatable {
    case idle, working, needsYou, done
}

public struct Usage: Sendable, Equatable {
    public var total: Int
    public var context: Int
    public init(total: Int, context: Int) {
        self.total = total
        self.context = context
    }
}

public struct Session: Sendable, Equatable, Identifiable {
    public let id: SessionKey
    public var state: SessionState
    public var seen: Bool
    public var cwd: String?
    public var project: String
    public var term: Term
    public var transcript: String?
    public var tool: String?
    public var promptStart: Int64?
    public var lastEvent: Int64
    public var pendingPrompts: Int
    public var permissionNotified: Bool
    public var usage: Usage?
    public var note: String?

    /// What `apply` would show without an open prompt or permission ping
    /// folded in. Not part of the seam, only SessionStore reads it.
    var baseState: SessionState

    public var pose: GhostPose {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .needsYou: return .needs
        case .done: return .done
        }
    }

    /// idle: under 20s since lastEvent. working: always. needsYou, done: while unseen.
    public func isMoving(nowMs: Int64) -> Bool {
        switch state {
        case .idle: return nowMs - lastEvent < 20_000
        case .working: return true
        case .needsYou, .done: return !seen
        }
    }
}

public enum Effect: Sendable, Equatable {
    case chirp(SessionKey, SessionState)
    case ping(SessionKey, String)
    case watchPID(SessionKey, Int32)
    case removed(SessionKey)
}

public struct SessionStore: Sendable, Equatable {
    public private(set) var sessions: [SessionKey: Session]

    public init() {
        sessions = [:]
    }

    /// needsYou first, then lastEvent descending.
    public var ordered: [Session] {
        sessions.values.sorted { a, b in
            let aWaiting = a.state == .needsYou
            let bWaiting = b.state == .needsYou
            if aWaiting != bWaiting { return aWaiting }
            return a.lastEvent > b.lastEvent
        }
    }

    public var waitingCount: Int {
        sessions.values.filter { $0.state == .needsYou }.count
    }

    public mutating func apply(_ e: Event) -> [Effect] {
        let key = e.key

        if e.event == "SessionEnd" {
            guard sessions.removeValue(forKey: key) != nil else { return [] }
            return [.removed(key)]
        }

        if sessions[key] == nil {
            sessions[key] = Session(
                id: key, state: .idle, seen: true, cwd: nil, project: "?",
                term: Term(), transcript: nil, tool: nil, promptStart: nil,
                lastEvent: e.ts, pendingPrompts: 0, permissionNotified: false,
                usage: nil, note: nil, baseState: .idle
            )
        }

        var s = sessions[key]!
        s.lastEvent = e.ts
        if let cwd = e.cwd {
            s.cwd = cwd
            s.project = Self.projectName(cwd)
        }
        if let transcript = e.transcript { s.transcript = transcript }

        var effects: [Effect] = []
        let mergedTerm = Self.mergeTerm(s.term, e.term)
        if let newPid = mergedTerm.pid, newPid != s.term.pid {
            effects.append(.watchPID(key, newPid))
        }
        s.term = mergedTerm

        switch e.event {
        case "SessionStart":
            s.baseState = .idle
        case "UserPromptSubmit":
            s.baseState = .working
            s.promptStart = e.ts
            s.permissionNotified = false
        case "PreToolUse":
            s.baseState = .working
            s.tool = ToolSummary.make(tool: e.tool, input: e.toolInput, cwd: s.cwd)
            s.permissionNotified = false
        case "PostToolUse", "PostToolUseFailure":
            s.baseState = .working
            s.tool = nil
            s.permissionNotified = false
        case "PermissionDenied":
            s.baseState = .working
            s.permissionNotified = false
        case "SubagentStart", "SubagentStop":
            s.baseState = .working
        case "Notification":
            if e.hook?["notification_type"]?.stringValue == "permission_prompt" {
                s.permissionNotified = true
            }
        case "Stop", "Interrupt":
            s.baseState = .done
            s.tool = nil
            s.permissionNotified = false
        default:
            break
        }

        sessions[key] = s
        effects.append(contentsOf: foldShownState(key, ts: e.ts, promptReason: nil))
        return effects
    }

    /// reason goes after "<project> · ", e.g. "needs approval: Bash npm test".
    public mutating func beginPrompt(_ key: SessionKey, reason: String, ts: Int64) -> [Effect] {
        guard var s = sessions[key] else { return [] }
        s.pendingPrompts += 1
        sessions[key] = s
        return foldShownState(key, ts: ts, promptReason: reason)
    }

    public mutating func endPrompt(_ key: SessionKey, ts: Int64) -> [Effect] {
        guard var s = sessions[key] else { return [] }
        s.pendingPrompts = max(0, s.pendingPrompts - 1)
        s.permissionNotified = false
        if s.pendingPrompts == 0 {
            s.baseState = .working
        }
        sessions[key] = s
        return foldShownState(key, ts: ts, promptReason: nil)
    }

    public mutating func markSeen(_ key: SessionKey) {
        sessions[key]?.seen = true
    }

    public mutating func markAllSeen() {
        for key in sessions.keys { sessions[key]?.seen = true }
    }

    public mutating func setUsage(_ key: SessionKey, _ usage: Usage) {
        sessions[key]?.usage = usage
    }

    public mutating func setNote(_ key: SessionKey, _ note: String?) {
        sessions[key]?.note = note
    }

    /// Soonest moment an idle ghost stops moving, for one asyncAfter.
    public func nextStillAt(nowMs: Int64) -> Int64? {
        sessions.values
            .filter { $0.state == .idle && $0.isMoving(nowMs: nowMs) }
            .map { $0.lastEvent + 20_000 }
            .min()
    }

    /// Recomputes the shown state from pendingPrompts/permissionNotified and
    /// emits chirp+ping only when it newly enters needsYou or done.
    private mutating func foldShownState(_ key: SessionKey, ts: Int64, promptReason: String?) -> [Effect] {
        guard var s = sessions[key] else { return [] }
        let newShown: SessionState = (s.pendingPrompts > 0 || s.permissionNotified) ? .needsYou : s.baseState
        defer { sessions[key] = s }

        guard newShown != s.state else { return [] }
        var effects: [Effect] = []
        if newShown == .needsYou || newShown == .done {
            s.seen = false
            effects.append(.chirp(key, newShown))
            let text: String
            if newShown == .done {
                text = "\(s.project) · done"
            } else if let promptReason {
                text = "\(s.project) · \(promptReason)"
            } else {
                text = "\(s.project) · needs you"
            }
            effects.append(.ping(key, text))
        }
        s.state = newShown
        return effects
    }

    private static func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "?" : name
    }

    /// term is recomputed by the hook on every event; if a field is missing
    /// on one line, keep the last value we had rather than blanking a row.
    private static func mergeTerm(_ old: Term, _ new: Term) -> Term {
        Term(
            pid: new.pid ?? old.pid,
            tty: new.tty ?? old.tty,
            program: new.program ?? old.program,
            cmuxSurface: new.cmuxSurface ?? old.cmuxSurface,
            cmuxWorkspace: new.cmuxWorkspace ?? old.cmuxWorkspace,
            cmuxSocket: new.cmuxSocket ?? old.cmuxSocket,
            cmuxCli: new.cmuxCli ?? old.cmuxCli
        )
    }
}
