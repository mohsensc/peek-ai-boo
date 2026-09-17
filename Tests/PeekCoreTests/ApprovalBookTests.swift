import Foundation
import Testing
@testable import PeekCore

private let npmTest = JSONValue.object(["command": .string("npm test")])
private let npmLint = JSONValue.object(["command": .string("npm run lint")])

private func request(_ ts: Int64, agent: String = "s1", client: Client = .claude,
                     tool: String? = "Bash", input: JSONValue? = npmTest,
                     want: String? = "decision") -> Event {
    var hook: [String: JSONValue] = ["hook_event_name": .string("PermissionRequest")]
    if let input { hook["tool_input"] = input }
    return Event(client: client, event: "PermissionRequest", agent: agent, ts: ts,
                 want: want, tool: tool, cwd: "/Users/m/src/sync", hook: .object(hook))
}

private func event(_ name: String, _ ts: Int64, agent: String = "s1",
                   tool: String? = nil, input: JSONValue? = nil) -> Event {
    Event(client: .claude, event: name, agent: agent, ts: ts, tool: tool,
          hook: input.map { .object(["tool_input": $0]) })
}

private let questionInput = JSONValue.parse(Data("""
{"questions":[{"question":"Which color?","header":"Color","multiSelect":false,
  "options":[{"label":"Red","description":""},{"label":"Blue","description":""}]}]}
""".utf8))!

/// #require can't take a mutating call directly.
private func open(_ book: inout ApprovalBook, _ e: Event) throws -> PendingPrompt {
    let p = book.open(e)
    return try #require(p)
}

@Suite struct ApprovalBookTests {
    // MARK: open

    @Test func opensClaudePermissionRequest() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        #expect(p.key == SessionKey(client: .claude, agent: "s1"))
        #expect(p.tool == "Bash")
        #expect(p.toolInput == npmTest)
        #expect(p.ts == 102)
        #expect(p.summary == "Bash npm test")
        #expect(p.questions == nil)
        #expect(p.hookGone == false)
        #expect(book.pending == [p])
    }

    @Test func codexNeverOpens() {
        var book = ApprovalBook()
        #expect(book.open(request(102, client: .codex)) == nil)
        #expect(book.pending.isEmpty)
    }

    @Test func onlyDecisionPermissionRequestsWithAToolOpen() {
        var book = ApprovalBook()
        #expect(book.open(request(102, tool: nil)) == nil)
        #expect(book.open(request(102, tool: "")) == nil)
        // Came in without a connection to answer on.
        #expect(book.open(request(102, want: nil)) == nil)
        #expect(book.open(event("PreToolUse", 102, tool: "Bash", input: npmTest)) == nil)
        #expect(book.pending.isEmpty)
    }

    @Test func droppedToolInputDoesNotOpen() {
        // The hook nulls `hook` past 256 KiB. Nobody should allow a Bash
        // call they can't read, so the terminal keeps this one.
        var book = ApprovalBook()
        #expect(book.open(request(102, input: nil)) == nil)
    }

    @Test func questionOpensWithQuestions() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102, tool: "AskUserQuestion", input: questionInput))
        #expect(p.questions?.count == 1)
        #expect(p.summary == "Which color?")
    }

    @Test func malformedQuestionDoesNotOpen() {
        // An Allow on AskUserQuestion isn't an answer, so a question we
        // can't draw is left to the terminal picker.
        var book = ApprovalBook()
        let bad = JSONValue.object(["questions": .array([])])
        #expect(book.open(request(102, tool: "AskUserQuestion", input: bad)) == nil)
    }

    // MARK: apply

    @Test func earlierPreToolUseDoesNotResolve() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        #expect(book.apply(event("PreToolUse", 100, tool: "Bash", input: npmTest)).isEmpty)
        #expect(book.pending.count == 1)
    }

    @Test func laterPostToolUseWithSameToolAndInputResolves() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        #expect(book.apply(event("PostToolUse", 150, tool: "Bash", input: npmTest)) == [p])
        #expect(book.pending.isEmpty)
    }

    @Test func postToolUseFailureResolvesToo() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        #expect(book.apply(event("PostToolUseFailure", 150, tool: "Bash", input: npmTest)) == [p])
    }

    @Test func postToolUseWithDifferentInputDoesNot() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        #expect(book.apply(event("PostToolUse", 150, tool: "Bash", input: npmLint)).isEmpty)
        #expect(book.apply(event("PostToolUse", 151, tool: "Read", input: npmTest)).isEmpty)
        #expect(book.apply(event("PostToolUse", 152, tool: "Bash", input: nil)).isEmpty)
        #expect(book.pending.count == 1)
    }

    @Test func earlierIdenticalPostToolUseDoesNot() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        #expect(book.apply(event("PostToolUse", 90, tool: "Bash", input: npmTest)).isEmpty)
        #expect(book.pending.count == 1)
    }

    @Test func sameMillisecondDoesNotResolve() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        #expect(book.apply(event("Stop", 102)).isEmpty)
    }

    @Test func sessionLevelEventsResolve() throws {
        for name in ["PreToolUse", "PermissionDenied", "UserPromptSubmit", "Stop", "SessionEnd"] {
            var book = ApprovalBook()
            let p = try open(&book, request(102))
            #expect(book.apply(event(name, 200)) == [p], "\(name)")
            #expect(book.pending.isEmpty, "\(name)")
        }
    }

    @Test func eventsThatDoNotResolve() throws {
        for name in ["Notification", "SubagentStart", "SubagentStop", "SessionStart", "PermissionRequest"] {
            var book = ApprovalBook()
            _ = try open(&book, request(102))
            #expect(book.apply(event(name, 200)).isEmpty, "\(name)")
        }
    }

    @Test func synthesizedSessionEndResolves() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        #expect(book.apply(.sessionEnd(p.key, ts: 103)) == [p])
    }

    @Test func anotherSessionsStopDoesNot() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        #expect(book.apply(event("Stop", 200, agent: "s2")).isEmpty)
        #expect(book.apply(Event(client: .codex, event: "Stop", agent: "s1", ts: 201)).isEmpty)
        #expect(book.pending.count == 1)
    }

    @Test func twoPromptsInOneSessionBothGoOnStop() throws {
        var book = ApprovalBook()
        let a = try open(&book, request(102))
        let b = try open(&book, request(103, input: npmLint))
        #expect(book.apply(event("Stop", 200)) == [a, b])
        #expect(book.pending.isEmpty)
    }

    @Test func onlyTheMatchingPromptGoesOnPostToolUse() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        let lint = try open(&book, request(103, input: npmLint))
        #expect(book.apply(event("PostToolUse", 200, tool: "Bash", input: npmLint)) == [lint])
        #expect(book.pending.map(\.toolInput) == [npmTest])
    }

    // MARK: identical requests

    @Test func identicalRequestsAreSeparatePrompts() throws {
        var book = ApprovalBook()
        let a = try open(&book, request(102))
        let b = try open(&book, request(102))
        #expect(a.id != b.id)
        #expect(book.take(a.id) == a)
        #expect(book.pending == [b])
        #expect(book.take(a.id) == nil)
        #expect(book.take(b.id) == b)
    }

    @Test func oneTerminalAnswerClosesBothIdenticalPrompts() throws {
        // Can't tell which of the two the terminal answered. Closing both
        // sends no reply, so the other one just falls back to the terminal.
        var book = ApprovalBook()
        let a = try open(&book, request(102))
        let b = try open(&book, request(104))
        #expect(book.apply(event("PostToolUse", 150, tool: "Bash", input: npmTest)) == [a, b])
    }

    // MARK: take and hookGone

    @Test func takeRemoves() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        #expect(book.take(p.id) == p)
        #expect(book.pending.isEmpty)
        #expect(book.take(p.id) == nil)
    }

    @Test func takeAfterResolveIsNil() throws {
        // The answer path only replies when take hands back a prompt, so
        // this is the "never allow a resolved request" check.
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        _ = book.apply(event("PostToolUse", 150, tool: "Bash", input: npmTest))
        #expect(book.take(p.id) == nil)
    }

    @Test func takeOfUnknownIDIsNil() {
        var book = ApprovalBook()
        #expect(book.take(UUID()) == nil)
    }

    // MARK: answering from a ping capsule
    //
    // The capsule's Deny/Allow buttons and the full panel's ApprovalRow call
    // the exact same take()-then-reply path (see Approvals.pingBindings and
    // Approvals.answer), so this is the same guarantee framed from that
    // caller: a capsule can answer its prompt, but never twice, and never
    // once something else has already resolved it.

    @Test func capsuleAnswersOnceThenIsInert() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        #expect(book.take(p.id) == p)            // Allow/Deny tapped once
        #expect(book.take(p.id) == nil)           // a second tap does nothing
        #expect(book.take(p.id) == nil)           // nor a third
    }

    @Test func capsuleCannotAnswerAfterTheTerminalResolvesItFirst() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        // The terminal answered (matching PostToolUse) before the capsule's
        // own buttons were tapped.
        #expect(book.apply(event("PostToolUse", 150, tool: "Bash", input: npmTest)) == [p])
        #expect(book.take(p.id) == nil)
    }

    @Test func capsuleCannotAnswerOnceItsHookIsGone() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        book.hookGone(p.id)
        // The row still shows ("answer in terminal"), but tapping it can't
        // reach a hook that already exited.
        #expect(book.take(p.id) == nil)
    }

    @Test func hookGoneKeepsThePromptButRefusesTake() throws {
        var book = ApprovalBook()
        let p = try open(&book, request(102))
        book.hookGone(p.id)
        #expect(book.pending.count == 1)
        #expect(book.pending[0].hookGone)
        #expect(book.take(p.id) == nil)
        #expect(book.pending.count == 1)
        // A later signal still clears the row.
        let resolved = book.apply(event("Stop", 200))
        #expect(resolved.map(\.id) == [p.id])
        #expect(resolved.first?.hookGone == true)
        #expect(book.pending.isEmpty)
    }

    @Test func hookGoneOnUnknownIDIsANoOp() throws {
        var book = ApprovalBook()
        _ = try open(&book, request(102))
        let before = book
        book.hookGone(UUID())
        #expect(book == before)
    }

    // MARK: arrival order

    // Events and decide lines come in on different sockets, so the terminal
    // answer can be applied before its own prompt is opened. Either order
    // has to end up in the same place.

    @Test func terminalAnswerAppliedBeforeOpenKeepsItClosed() {
        var book = ApprovalBook()
        _ = book.apply(event("PostToolUse", 150, tool: "Bash", input: npmTest))
        #expect(book.open(request(102)) == nil)
        #expect(book.pending.isEmpty)
    }

    @Test func laterSessionEventAppliedBeforeOpenKeepsItClosed() {
        for name in ["PreToolUse", "PermissionDenied", "UserPromptSubmit", "Stop", "SessionEnd"] {
            var book = ApprovalBook()
            _ = book.apply(event(name, 200))
            #expect(book.open(request(102)) == nil, "\(name)")
        }
    }

    @Test func earlierEventsAppliedFirstDoNotBlockOpen() throws {
        var book = ApprovalBook()
        _ = book.apply(event("UserPromptSubmit", 50))
        _ = book.apply(event("PreToolUse", 100, tool: "Bash", input: npmTest))
        _ = book.apply(event("PostToolUse", 101, tool: "Bash", input: npmTest))
        _ = book.apply(event("Stop", 200, agent: "s2"))
        _ = book.apply(event("PostToolUse", 300, tool: "Bash", input: npmLint))
        _ = try open(&book, request(102))
    }

    @Test func sameRequestAgainAfterAnAnsweredOneOpens() throws {
        var book = ApprovalBook()
        let first = try open(&book, request(102))
        #expect(book.apply(event("PostToolUse", 150, tool: "Bash", input: npmTest)) == [first])
        // Claude asks for the identical call again later.
        _ = book.apply(event("PreToolUse", 180, tool: "Bash", input: npmTest))
        _ = try open(&book, request(182))
    }

    @Test func orderDoesNotMatter() {
        let events = [
            event("PreToolUse", 100, tool: "Bash", input: npmTest),
            event("PostToolUse", 150, tool: "Bash", input: npmLint),
            event("PostToolUse", 160, tool: "Bash", input: npmTest),
            event("Stop", 170, agent: "s2"),
        ]
        for split in 0...events.count {
            var book = ApprovalBook()
            for e in events[..<split] { _ = book.apply(e) }
            let opened = book.open(request(102))
            var resolved: [PendingPrompt] = []
            for e in events[split...] { resolved += book.apply(e) }
            // Either it never opens, or it opens and a later event closes it.
            #expect(book.pending.isEmpty, "split \(split)")
            if let opened { #expect(resolved == [opened], "split \(split)") }
        }
    }

    @Test func rememberedPostsStayBounded() {
        var book = ApprovalBook()
        for i in 0..<1000 {
            _ = book.apply(event("PostToolUse", Int64(1000 + i), tool: "Bash",
                                 input: .object(["command": .string("echo \(i)")])))
        }
        #expect(book.rememberedPosts(SessionKey(client: .claude, agent: "s1")) <= ApprovalBook.postMemory)
        _ = book.apply(event("PreToolUse", 5000))
        #expect(book.rememberedPosts(SessionKey(client: .claude, agent: "s1")) == 0)
    }
}
