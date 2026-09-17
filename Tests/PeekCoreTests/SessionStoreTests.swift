import Foundation
import Testing
@testable import PeekCore

private func ev(_ event: String, ts: Int64, cwd: String? = "/Users/m/src/sync",
                 tool: String? = nil, toolInput: JSONValue? = nil,
                 hook: JSONValue? = nil, pid: Int32? = 1) -> Event {
    Event(
        client: .claude, event: event, agent: "sess-1", ts: ts,
        tool: tool, cwd: cwd, term: Term(pid: pid),
        hook: hook ?? toolInput.map { .object(["tool_input": $0]) }
    )
}

@Suite struct SessionStoreTests {
    @Test func unknownKeyCreatesSessionSeenTrue() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        #expect(store.sessions[SessionKey(client: .claude, agent: "sess-1")]?.seen == true)
    }

    @Test func sessionStartIsIdle() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        #expect(session(store).state == .idle)
    }

    @Test func userPromptSubmitIsWorking() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("UserPromptSubmit", ts: 2))
        let s = session(store)
        #expect(s.state == .working)
        #expect(s.promptStart == 2)
        #expect(s.permissionNotified == false)
    }

    @Test func preToolUseSetsToolAndWorking() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        let input = JSONValue.object(["command": .string("npm test")])
        _ = store.apply(ev("PreToolUse", ts: 2, tool: "Bash", toolInput: input))
        let s = session(store)
        #expect(s.state == .working)
        #expect(s.tool == "Bash npm test")
    }

    @Test func postToolUseClearsTool() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("PreToolUse", ts: 2, tool: "Bash"))
        _ = store.apply(ev("PostToolUse", ts: 3))
        #expect(session(store).tool == nil)
        #expect(session(store).state == .working)
    }

    @Test func postToolUseFailureIsWorking() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("PostToolUseFailure", ts: 2))
        #expect(session(store).state == .working)
    }

    @Test func permissionDeniedSubagentStartStopAreWorking() {
        for name in ["PermissionDenied", "SubagentStart", "SubagentStop"] {
            var store = SessionStore()
            _ = store.apply(ev("SessionStart", ts: 1))
            _ = store.apply(ev(name, ts: 2))
            #expect(session(store).state == .working, "\(name) should be working")
        }
    }

    @Test func permissionPromptNotificationEntersNeedsYou() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("UserPromptSubmit", ts: 2))
        let hook = JSONValue.object(["notification_type": .string("permission_prompt")])
        let effects = store.apply(ev("Notification", ts: 3, hook: hook))
        #expect(session(store).state == .needsYou)
        #expect(effects.contains(.chirp(key, .needsYou)))
    }

    @Test func otherNotificationsChangeNothing() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("UserPromptSubmit", ts: 2))
        let hook = JSONValue.object(["notification_type": .string("something_else")])
        _ = store.apply(ev("Notification", ts: 3, hook: hook))
        #expect(session(store).state == .working)
    }

    @Test func stopIsDoneAndClearsTool() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("PreToolUse", ts: 2, tool: "Bash"))
        let effects = store.apply(ev("Stop", ts: 3))
        let s = session(store)
        #expect(s.state == .done)
        #expect(s.tool == nil)
        #expect(effects.contains(.chirp(key, .done)))
    }

    @Test func interruptIsDone() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("Interrupt", ts: 2))
        #expect(session(store).state == .done)
    }

    @Test func chirpOnlyFiresOnEnteringNotLeaving() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        let hook = JSONValue.object(["notification_type": .string("permission_prompt")])
        let entering = store.apply(ev("Notification", ts: 2, hook: hook))
        #expect(entering.contains(where: { if case .chirp = $0 { return true }; return false }))

        // PreToolUse clears permissionNotified, so this leaves needsYou.
        let leaving = store.apply(ev("PreToolUse", ts: 3, tool: "Bash"))
        #expect(!leaving.contains(where: { if case .chirp = $0 { return true }; return false }))
        #expect(session(store).state == .working)
    }

    @Test func sessionEndRemovesAndEmitsRemoved() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        let effects = store.apply(Event.sessionEnd(key, ts: 2))
        #expect(store.sessions[key] == nil)
        #expect(effects == [.removed(key)])
    }

    @Test func beginPromptEntersNeedsYou() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("PreToolUse", ts: 2, tool: "Bash"))
        let effects = store.beginPrompt(key, ts: 3)
        #expect(session(store).state == .needsYou)
        #expect(effects.contains(.chirp(key, .needsYou)))
    }

    @Test func endPromptDropsToWorkingWhenNothingPending() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("PreToolUse", ts: 2, tool: "Bash"))
        _ = store.beginPrompt(key, ts: 3)
        _ = store.endPrompt(key)
        let s = session(store)
        #expect(s.state == .working)
        #expect(s.pendingPrompts == 0)
        #expect(s.permissionNotified == false)
    }

    @Test func endPromptAfterStopStaysDone() {
        // A Stop can resolve the last pending prompt, and endPrompt runs
        // after it. The session should stay done, not bounce back to working.
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("PreToolUse", ts: 2, tool: "Bash"))
        _ = store.beginPrompt(key, ts: 3)
        _ = store.apply(ev("Stop", ts: 4))
        _ = store.endPrompt(key)
        #expect(session(store).state == .done)
    }

    @Test func endPromptNeverGoesBelowZero() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.endPrompt(key)
        #expect(session(store).pendingPrompts == 0)
    }

    @Test func firstPidEmitsWatchPIDChangedPidEmitsAgain() {
        var store = SessionStore()
        let first = store.apply(ev("SessionStart", ts: 1, pid: 100))
        #expect(first.contains(.watchPID(key, 100)))
        let same = store.apply(ev("PreToolUse", ts: 2, pid: 100))
        #expect(!same.contains(where: { if case .watchPID = $0 { return true }; return false }))
        let changed = store.apply(ev("PreToolUse", ts: 3, pid: 200))
        #expect(changed.contains(.watchPID(key, 200)))
    }

    @Test func isMovingRules() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1000))
        let idleSession = session(store)
        #expect(idleSession.isMoving(nowMs: 1000 + 19_999) == true)
        #expect(idleSession.isMoving(nowMs: 1000 + 20_001) == false)

        _ = store.apply(ev("UserPromptSubmit", ts: 2000))
        #expect(session(store).isMoving(nowMs: 999_999_999) == true)   // working: always

        // needsYou: moving for a short wave from the ping that caused it,
        // then still even though it's still unseen (that's the CPU fix, not
        // a bug — see needsYouWaveHoldsStillAfterTheWave below), and never
        // moving at all once seen, wave or not.
        let hook = JSONValue.object(["notification_type": .string("permission_prompt")])
        _ = store.apply(ev("Notification", ts: 3000, hook: hook))
        var needsYou = session(store)
        #expect(needsYou.seen == false)
        #expect(needsYou.isMoving(nowMs: 3000 + 4_999) == true)    // within the wave
        #expect(needsYou.isMoving(nowMs: 3000 + 5_001) == false)   // past it, still unseen
        store.markSeen(key)
        needsYou = session(store)
        #expect(needsYou.isMoving(nowMs: 3000 + 1) == false)  // seen beats an active wave too
    }

    @Test func needsYouWaveHoldsStillAfterTheWave() {
        // The wave plays for needsYouWaveMs from the ping that started it,
        // then holds the needs-you pose on frame 0 (isMoving == false) while
        // the ping itself stays up (still unseen) — no timer needed to get
        // there, isMoving is just a pure function of elapsed time.
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 0))
        _ = store.apply(ev("PreToolUse", ts: 1, tool: "Bash"))
        _ = store.beginPrompt(key, ts: 1_000)
        let waiting = session(store)
        #expect(waiting.isMoving(nowMs: 1_000) == true)
        #expect(waiting.isMoving(nowMs: 1_000 + Session.needsYouWaveMs - 1) == true)
        #expect(waiting.isMoving(nowMs: 1_000 + Session.needsYouWaveMs) == false)
        #expect(waiting.isMoving(nowMs: 999_999_999) == false)
    }

    @Test func aSecondPingRestartsTheWave() {
        // Two approvals stack on the same session: the first's wave already
        // finished, and the second beginPrompt (a new ping) restarts it —
        // even though the session was already needsYou the whole time, so
        // foldShownState's own state-changed branch never fires for this one.
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 0))
        _ = store.apply(ev("PreToolUse", ts: 1, tool: "Bash"))
        _ = store.beginPrompt(key, ts: 1_000)
        #expect(session(store).isMoving(nowMs: 1_000 + Session.needsYouWaveMs) == false)

        _ = store.beginPrompt(key, ts: 10_000)
        let restarted = session(store)
        #expect(restarted.state == .needsYou)   // no transition; still already needsYou
        #expect(restarted.isMoving(nowMs: 10_000) == true)
        #expect(restarted.isMoving(nowMs: 10_000 + Session.needsYouWaveMs) == false)
    }

    @Test func nextStillAtTracksIdleSessions() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1000))
        let expected: Int64 = 1000 + 20_000
        #expect(store.nextStillAt(nowMs: 1000) == expected)
        #expect(store.nextStillAt(nowMs: 1000 + 20_001) == nil)
    }

    @Test func nextStillAtTracksAWaitingNeedsYouSession() {
        // This is what actually protects the CPU win: without it,
        // AppModel never gets a wakeup at the 5s mark and the ghost keeps
        // waving until some unrelated event happens to force a render.
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 0))
        _ = store.apply(ev("PreToolUse", ts: 1, tool: "Bash"))
        _ = store.beginPrompt(key, ts: 2_000)
        let expected: Int64 = 2_000 + Session.needsYouWaveMs
        #expect(store.nextStillAt(nowMs: 2_000) == expected)
        #expect(store.nextStillAt(nowMs: expected + 1) == nil)
    }

    @Test func orderedPutsNeedsYouFirstThenNewestFirst() {
        var store = SessionStore()
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "a", ts: 1))
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "b", ts: 5))
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "c", ts: 2))
        let hook = JSONValue.object(["notification_type": .string("permission_prompt")])
        _ = store.apply(Event(client: .claude, event: "UserPromptSubmit", agent: "a", ts: 3))
        _ = store.apply(Event(client: .claude, event: "Notification", agent: "a", ts: 4, hook: hook))

        let ordered = store.ordered.map { $0.id.agent }
        #expect(ordered == ["a", "b", "c"])   // needsYou first, then lastEvent descending
        #expect(store.waitingCount == 1)
    }

    @Test func claudeBasicFixtureEndToEnd() throws {
        let data = try Data(contentsOf: fixture("claude-basic.jsonl"))
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { Data($0.utf8) }
        var store = SessionStore()
        let sessKey = SessionKey(client: .claude, agent: "sess-1")

        for (i, line) in lines.enumerated() {
            guard let e = Event.parse(line) else {
                Issue.record("line \(i) failed to parse")
                continue
            }
            _ = store.apply(e)
            switch i {
            case 0: #expect(store.sessions[sessKey]?.state == .idle)
            case 1: #expect(store.sessions[sessKey]?.state == .working)
            case 2: #expect(store.sessions[sessKey]?.tool == "Bash npm test")
            case 3: #expect(store.sessions[sessKey]?.tool == nil)
            case 4: #expect(store.sessions[sessKey]?.state == .needsYou)
            case 5: #expect(store.sessions[sessKey]?.state == .working)
            case 6: #expect(store.sessions[sessKey]?.tool == nil)
            case 7: #expect(store.sessions[sessKey]?.state == .done)
            default: break
            }
        }
        #expect(store.sessions[sessKey] == nil)   // SessionEnd removed it
    }

    // MARK: info pings

    @Test func doneAndUnseenIsAnInfoPingUntilClicked() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("Stop", ts: 2))
        #expect(store.infoPings.map(\.id) == [key])

        // No timer involved: it just sits there, however long that takes.
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "sess-2", ts: 999_999))
        #expect(store.infoPings.map(\.id) == [key])

        store.markSeen(key)
        #expect(store.infoPings.isEmpty)
    }

    @Test func workingOrIdleSessionsAreNeverInfoPings() {
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        #expect(store.infoPings.isEmpty)
        _ = store.apply(ev("UserPromptSubmit", ts: 2))
        #expect(store.infoPings.isEmpty)
    }

    @Test func seenDoneIsNotAnInfoPing() {
        // Stop from a session that was already marked seen (e.g. its ghost
        // was watched to completion) shouldn't newly need acknowledgement --
        // foldShownState only flips seen=false on entering needsYou/done.
        var store = SessionStore()
        _ = store.apply(ev("SessionStart", ts: 1))
        _ = store.apply(ev("Stop", ts: 2))
        store.markSeen(key)
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "sess-2", ts: 3))
        #expect(store.infoPings.isEmpty)
    }

    @Test func infoPingsAreOldestEventFirst() {
        var store = SessionStore()
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "later", ts: 1))
        _ = store.apply(Event(client: .claude, event: "SessionStart", agent: "earlier", ts: 1))
        _ = store.apply(Event(client: .claude, event: "Stop", agent: "later", ts: 20))
        _ = store.apply(Event(client: .claude, event: "Stop", agent: "earlier", ts: 10))
        #expect(store.infoPings.map(\.id.agent) == ["earlier", "later"])
    }

    private var key: SessionKey { SessionKey(client: .claude, agent: "sess-1") }
    private func session(_ store: SessionStore) -> Session {
        store.sessions[SessionKey(client: .claude, agent: "sess-1")]!
    }
}
