import Foundation
import Testing
@testable import PeekCore

@Suite struct CodexHooksTests {
    @Test func nineEventsInOrder() {
        let names = CodexHooks.spec.events.map(\.name)
        #expect(names == [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "SubagentStart", "SubagentStop", "Stop", "Interrupt", "SessionEnd",
        ])
    }

    @Test func timeoutsCapSessionEndAndInterruptAtThree() {
        for e in CodexHooks.spec.events {
            switch e.name {
            case "SessionEnd", "Interrupt": #expect(e.timeout == 3, "\(e.name) should cap at 3")
            default: #expect(e.timeout == 5, "\(e.name) should be 5")
            }
        }
    }

    @Test func matcherOnlyOnToolEvents() {
        for e in CodexHooks.spec.events {
            switch e.name {
            case "PreToolUse", "PostToolUse": #expect(e.matcher == "*")
            default: #expect(e.matcher == nil, "\(e.name) shouldn't carry a matcher")
            }
        }
    }

    @Test func configPathAndAfterChange() {
        #expect(CodexHooks.spec.client == .codex)
        #expect(CodexHooks.spec.configPath == ".codex/hooks.json")
        #expect(CodexHooks.spec.afterChange == "Codex: run /hooks once to trust the new entries.")
    }
}

@Suite struct CodexUsageTests {
    @Test func fixtureTotalsLatestLineWins() throws {
        var reader = CodexUsage()
        let data = try Data(contentsOf: fixture("codex-rollout.jsonl"))
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            reader.feed(Data(line.utf8))
        }
        #expect(reader.usage == Usage(total: 2500, context: 300))
    }

    @Test func nullInfoIsSkipped() {
        var reader = CodexUsage()
        reader.feed(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8))
        #expect(reader.usage == nil)
    }

    @Test func junkAndUnrelatedLinesAreSkipped() {
        var reader = CodexUsage()
        reader.feed(Data("not json at all".utf8))
        reader.feed(Data(#"{"type":"session_meta","payload":{"session_id":"x"}}"#.utf8))
        reader.feed(Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8))
        #expect(reader.usage == nil)
    }

    @Test func transcriptPathPrefersTheEventField() {
        let reader = CodexUsage()
        let e = Event(client: .codex, event: "Stop", agent: "sess-1", ts: 1, transcript: "/explicit/path.jsonl")
        #expect(reader.transcriptPath(for: e, home: "/wherever") == "/explicit/path.jsonl")
    }

    @Test func transcriptPathFallsBackToNewestMatchingDay() throws {
        let home = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let older = home.appendingPathComponent(".codex/sessions/2026/08/20")
        let newer = home.appendingPathComponent(".codex/sessions/2026/09/12")
        try fm.createDirectory(at: older, withIntermediateDirectories: true)
        try fm.createDirectory(at: newer, withIntermediateDirectories: true)
        let oldFile = older.appendingPathComponent("rollout-2026-08-20T00-00-00-sess-1.jsonl")
        let newFile = newer.appendingPathComponent("rollout-2026-09-12T00-00-00-sess-1.jsonl")
        try Data().write(to: oldFile)
        try Data().write(to: newFile)

        let reader = CodexUsage()
        let e = Event(client: .codex, event: "Stop", agent: "sess-1", ts: 1)
        #expect(reader.transcriptPath(for: e, home: home.path) == newFile.path)
    }

    @Test func transcriptPathNilWhenNothingMatches() throws {
        let home = try shortTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = CodexUsage()
        let e = Event(client: .codex, event: "Stop", agent: "sess-1", ts: 1)
        #expect(reader.transcriptPath(for: e, home: home.path) == nil)
    }
}

@Suite struct CodexSessionFixtureTests {
    @Test func codexSessionFixtureEndToEnd() throws {
        let data = try Data(contentsOf: fixture("codex-session.jsonl"))
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { Data($0.utf8) }
        var store = SessionStore()
        let stopped = SessionKey(client: .codex, agent: "codex-1")
        let interrupted = SessionKey(client: .codex, agent: "codex-2")

        for (i, line) in lines.enumerated() {
            guard let e = Event.parse(line) else {
                Issue.record("line \(i) failed to parse")
                continue
            }
            _ = store.apply(e)
            switch i {
            case 0: #expect(store.sessions[stopped]?.state == .idle)
            case 1: #expect(store.sessions[stopped]?.state == .working)
            case 2: #expect(store.sessions[stopped]?.tool != nil)
            case 3: #expect(store.sessions[stopped]?.tool == nil)
            case 4: #expect(store.sessions[stopped]?.state == .done)   // Stop
            case 8: #expect(store.sessions[interrupted]?.state == .done)   // Interrupt
            default: break
            }
        }
        #expect(store.sessions[stopped] == nil)       // SessionEnd removed it
        #expect(store.sessions[interrupted] == nil)   // SessionEnd removed it
    }

    @Test func codexEventsNeverTouchPendingPrompts() {
        var store = SessionStore()
        let key = SessionKey(client: .codex, agent: "c")
        let names = [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "SubagentStart", "SubagentStop", "Interrupt",
        ]
        for (i, name) in names.enumerated() {
            _ = store.apply(Event(client: .codex, event: name, agent: "c", ts: Int64(i + 1)))
        }
        #expect(store.sessions[key]?.pendingPrompts == 0)
    }
}
