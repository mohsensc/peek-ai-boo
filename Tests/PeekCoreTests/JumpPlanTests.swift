import Foundation
import Testing
@testable import PeekCore

@Suite struct JumpPlanTests {
    @Test func cmuxBeatsGhosttyWhenBothSet() {
        // cmux sets TERM_PROGRAM=ghostty too, so the surface check has to win.
        let term = Term(
            program: "ghostty", cmuxSurface: "surface-1", cmuxWorkspace: "ws-1",
            cmuxSocket: "/tmp/s.sock", cmuxCli: "/path/cmux"
        )
        let plan = JumpPlan.make(term: term, cwd: "/Users/m/src")
        #expect(plan == .cmux(
            cli: "/path/cmux", socket: "/tmp/s.sock",
            commands: [["select-workspace", "--workspace", "ws-1"], ["focus-panel", "--panel", "surface-1"]]
        ))
    }

    @Test func cmuxOmitsSelectWorkspaceWhenNil() {
        let term = Term(cmuxSurface: "surface-1", cmuxCli: "/path/cmux")
        let plan = JumpPlan.make(term: term, cwd: nil)
        #expect(plan == .cmux(cli: "/path/cmux", socket: nil, commands: [["focus-panel", "--panel", "surface-1"]]))
    }

    @Test func cmuxWithoutCliIsNone() {
        let term = Term(cmuxSurface: "surface-1")
        #expect(JumpPlan.make(term: term, cwd: nil) == .none(reason: "cmux cli missing"))
    }

    @Test func ghosttyNeedsCwd() {
        let term = Term(program: "ghostty")
        #expect(JumpPlan.make(term: term, cwd: nil) == .none(reason: "no terminal info"))
    }

    @Test func ghosttyUsesCwd() {
        let term = Term(program: "ghostty")
        let plan = JumpPlan.make(term: term, cwd: "/Users/m/src/sync")
        #expect(plan == .ghostty(script: AppleScriptText.ghostty(cwd: "/Users/m/src/sync")))
    }

    @Test func terminalAppNeedsTty() {
        let term = Term(program: "Apple_Terminal")
        #expect(JumpPlan.make(term: term, cwd: "/Users/m") == .none(reason: "no terminal info"))
    }

    @Test func terminalAppUsesTty() {
        let term = Term(tty: "/dev/ttys004", program: "Apple_Terminal")
        let plan = JumpPlan.make(term: term, cwd: nil)
        #expect(plan == .terminalApp(script: AppleScriptText.terminalApp(tty: "/dev/ttys004")))
    }

    @Test func unknownProgramNamesItInTheReason() {
        let term = Term(tty: "/dev/ttys005", program: "iTerm2")
        #expect(JumpPlan.make(term: term, cwd: nil) == .none(reason: "can't jump to iTerm2"))
    }

    @Test func emptyTermHasNoTerminalInfo() {
        #expect(JumpPlan.make(term: Term(), cwd: nil) == .none(reason: "no terminal info"))
    }
}

@Suite struct AppleScriptTextTests {
    @Test func quotedEscapesBackslashAndQuote() {
        #expect(AppleScriptText.quoted(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test func ghosttyScriptCompiles() {
        let source = AppleScriptText.ghostty(cwd: #"/Users/m/src/"weird" \path"#)
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        #expect(script?.compileAndReturnError(&error) == true)
        #expect(error == nil)
    }

    @Test func terminalAppScriptCompiles() {
        let source = AppleScriptText.terminalApp(tty: "/dev/ttys004")
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        #expect(script?.compileAndReturnError(&error) == true)
        #expect(error == nil)
    }
}
