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
    /// ts of the event that most recently put this session into needsYou (a
    /// fresh ping, not just a continuing one — see foldShownState/beginPrompt).
    /// 0 rather than optional: a path that forgets to set it makes the ghost
    /// never wave (loud, visible in a capture) instead of waving forever
    /// (the exact bug this exists to fix).
    public var needsYouWaveStart: Int64

    /// What `apply` would show without an open prompt or permission ping
    /// folded in. Not part of the seam, only SessionStore reads it.
    var baseState: SessionState

    /// How long the needsYou wave plays before holding still on frame 0.
    public static let needsYouWaveMs: Int64 = 5_000

    public var pose: GhostPose {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .needsYou: return .needs
        case .done: return .done
        }
    }

    /// idle: under 20s since lastEvent. working: always. needsYou: unseen and
    /// still within the short wave that started at needsYouWaveStart — after
    /// that it holds still on the needs-you pose even though still unseen,
    /// which is the whole CPU win (see IslandView.AnimatedGhostRow). done:
    /// while unseen, unchanged.
    public func isMoving(nowMs: Int64) -> Bool {
        switch state {
        case .idle: return nowMs - lastEvent < 20_000
        case .working: return true
        case .needsYou: return !seen && nowMs - needsYouWaveStart < Session.needsYouWaveMs
        case .done: return !seen
        }
    }
}

public enum Effect: Sendable, Equatable {
    case chirp(SessionKey, SessionState)
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

    /// Unseen "done" sessions, each worth one info ping capsule under the
    /// pill, oldest event first. No timer behind this — it's the same
    /// state/seen bookkeeping `ordered` already reads, so a session stays
    /// here until `markSeen` runs, however long that takes.
    public var infoPings: [Session] {
        sessions.values
            .filter { $0.state == .done && !$0.seen }
            .sorted { $0.lastEvent < $1.lastEvent }
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
                usage: nil, note: nil, needsYouWaveStart: 0, baseState: .idle
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
        effects.append(contentsOf: foldShownState(key, ts: e.ts))
        return effects
    }

    /// No `ts` parameter of its own for moving `lastEvent`: pendingPrompts is
    /// desk-driven bookkeeping, not a session event, so it doesn't bump a
    /// session in `ordered` just because a prompt opened or closed. `ts` is
    /// still threaded through to `needsYouWaveStart`, since a new pending
    /// prompt is exactly "a new ping" — set unconditionally (not just on a
    /// state transition) so a second prompt arriving while already needsYou
    /// restarts the wave same as the first one did.
    public mutating func beginPrompt(_ key: SessionKey, ts: Int64) -> [Effect] {
        guard var s = sessions[key] else { return [] }
        s.pendingPrompts += 1
        s.needsYouWaveStart = ts
        sessions[key] = s
        return foldShownState(key, ts: ts)
    }

    public mutating func endPrompt(_ key: SessionKey) -> [Effect] {
        guard var s = sessions[key] else { return [] }
        s.pendingPrompts = max(0, s.pendingPrompts - 1)
        s.permissionNotified = false
        // A Stop that resolved the last pending prompt already moved this
        // to done; going back to working would leave the ghost animating
        // forever, so done wins here.
        if s.pendingPrompts == 0 && s.baseState != .done {
            s.baseState = .working
        }
        // Resolving a prompt never enters needsYou, only leaves it, so this
        // ts is never actually read — s.lastEvent is just a sane stand-in.
        let ts = s.lastEvent
        sessions[key] = s
        return foldShownState(key, ts: ts)
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

    /// Soonest moment a currently-moving ghost goes still on its own, for one
    /// asyncAfter: an idle ghost 20s after its last event, or a needsYou
    /// ghost `needsYouWaveMs` after its wave started. Either way the caller
    /// (AppModel.scheduleStillCheck) just needs one wakeup, not a timer.
    public func nextStillAt(nowMs: Int64) -> Int64? {
        let idleDeadlines = sessions.values
            .filter { $0.state == .idle && $0.isMoving(nowMs: nowMs) }
            .map { $0.lastEvent + 20_000 }
        let waveDeadlines = sessions.values
            .filter { $0.state == .needsYou && $0.isMoving(nowMs: nowMs) }
            .map { $0.needsYouWaveStart + Session.needsYouWaveMs }
        return (idleDeadlines + waveDeadlines).min()
    }

    /// Recomputes the shown state from pendingPrompts/permissionNotified and
    /// emits a chirp only when it newly enters needsYou or done. Whether to
    /// show a ping capsule for that is derived state, not an effect here —
    /// see Approvals.pending and SessionStore.infoPings. `ts` backs
    /// needsYouWaveStart on a fresh entry into needsYou (permission_prompt
    /// Notification, the only path into needsYou that doesn't already go
    /// through beginPrompt's own unconditional set).
    private mutating func foldShownState(_ key: SessionKey, ts: Int64) -> [Effect] {
        guard var s = sessions[key] else { return [] }
        let newShown: SessionState = (s.pendingPrompts > 0 || s.permissionNotified) ? .needsYou : s.baseState
        defer { sessions[key] = s }

        guard newShown != s.state else { return [] }
        var effects: [Effect] = []
        if newShown == .needsYou || newShown == .done {
            s.seen = false
            effects.append(.chirp(key, newShown))
        }
        if newShown == .needsYou {
            s.needsYouWaveStart = ts
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
