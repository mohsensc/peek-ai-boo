import Foundation
import Testing
@testable import PeekCore

@Suite struct EventTests {
    static let fullLine = """
    {"v":1,"client":"claude","event":"PreToolUse","verb":"run","agent":"sess-1",
     "tool":"Bash","tool_use_id":"toolu_1","prompt_id":"prompt-1","cwd":"/Users/m/src/sync",
     "transcript":"/Users/m/.claude/projects/x/sess-1.jsonl","ts":1789811779123,
     "term":{"pid":4242,"tty":"/dev/ttys004","program":"ghostty","cmux_surface":"surf",
     "cmux_workspace":"ws","cmux_socket":"sock","cmux_cli":"cli"},"trunc":true,
     "hook":{"tool_input":{"command":"npm test"}}}
    """

    @Test func fullExampleLineParses() {
        let e = Event.parse(Data(Self.fullLine.utf8))
        #expect(e?.client == .claude)
        #expect(e?.event == "PreToolUse")
        #expect(e?.verb == "run")
        #expect(e?.agent == "sess-1")
        #expect(e?.tool == "Bash")
        #expect(e?.toolUseID == "toolu_1")
        #expect(e?.promptID == "prompt-1")
        #expect(e?.cwd == "/Users/m/src/sync")
        #expect(e?.transcript == "/Users/m/.claude/projects/x/sess-1.jsonl")
        #expect(e?.ts == 1789811779123)
        #expect(e?.trunc == true)
        #expect(e?.term.pid == 4242)
        #expect(e?.term.tty == "/dev/ttys004")
        #expect(e?.term.program == "ghostty")
        #expect(e?.term.cmuxSurface == "surf")
        #expect(e?.term.cmuxWorkspace == "ws")
        #expect(e?.term.cmuxSocket == "sock")
        #expect(e?.term.cmuxCli == "cli")
        #expect(e?.toolInput?["command"]?.stringValue == "npm test")
        #expect(e?.key == SessionKey(client: .claude, agent: "sess-1"))
        #expect(e?.wantsDecision == false)
    }

    @Test func missingAgentIsNil() {
        let line = #"{"v":1,"client":"claude","event":"Stop","ts":1}"#
        #expect(Event.parse(Data(line.utf8)) == nil)
    }

    @Test func emptyAgentIsNil() {
        let line = #"{"v":1,"client":"claude","event":"Stop","agent":"","ts":1}"#
        #expect(Event.parse(Data(line.utf8)) == nil)
    }

    @Test func wrongVersionIsNil() {
        let line = #"{"v":2,"client":"claude","event":"Stop","agent":"a","ts":1}"#
        #expect(Event.parse(Data(line.utf8)) == nil)
    }

    @Test func unknownClientIsNil() {
        let line = #"{"v":1,"client":"gemini","event":"Stop","agent":"a","ts":1}"#
        #expect(Event.parse(Data(line.utf8)) == nil)
    }

    @Test func missingEventIsNil() {
        let line = #"{"v":1,"client":"claude","agent":"a","ts":1}"#
        #expect(Event.parse(Data(line.utf8)) == nil)
    }

    @Test func missingTsIsNil() {
        let line = #"{"v":1,"client":"claude","event":"Stop","agent":"a"}"#
        #expect(Event.parse(Data(line.utf8)) == nil)
    }

    @Test func notJSONIsNil() {
        #expect(Event.parse(Data("nope".utf8)) == nil)
    }

    @Test func wantsDecisionWhenWantIsDecision() {
        let line = #"{"v":1,"client":"claude","event":"PermissionRequest","agent":"a","ts":1,"want":"decision"}"#
        #expect(Event.parse(Data(line.utf8))?.wantsDecision == true)
    }

    @Test func sessionEndBuildsRightKey() {
        let key = SessionKey(client: .codex, agent: "sess-9")
        let e = Event.sessionEnd(key, ts: 42)
        #expect(e.key == key)
        #expect(e.event == "SessionEnd")
        #expect(e.ts == 42)
    }
}
