import Foundation
import Testing
@testable import PeekCore

// Drives ApprovalDesk over real sockets. The waiting side is either
// scripts/fake-hook.py or the real hook binary, so no Claude session needed.

private let approvalInput = JSONValue.object([
    "command": .string("npm test"), "description": .string("Run the test suite"),
])

/// What main.swift and AppModel do around the desk: an events socket that
/// feeds every event to `observe`, and an ingest that does the same.
@MainActor
private final class Rig {
    let dir: URL
    var desk: ApprovalDesk!
    var events: LineServer!
    private(set) var ingested: [Event] = []
    private(set) var opened: [PendingPrompt] = []
    private(set) var ended: [PendingPrompt] = []
    /// Call order across ingest and opened.
    private(set) var log: [String] = []

    init() throws {
        dir = try shortTempDir()
        desk = try ApprovalDesk(
            path: dir.appendingPathComponent("decide.sock").path,
            ingest: { [unowned self] in self.feed($0) },
            opened: { [unowned self] in
                self.opened.append($0)
                self.log.append("opened")
            },
            changed: {}
        )
        events = try LineServer(
            path: dir.appendingPathComponent("events.sock").path,
            queue: DispatchQueue(label: "rig.events")
        ) { [weak self] data, connection in
            connection.close()
            guard let event = Event.parse(data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.feed(event) }
            }
        }
    }

    func feed(_ event: Event) {
        ingested.append(event)
        log.append("ingest \(event.event)")
        ended += desk.observe(event)
    }

    var pending: [PendingPrompt] { desk.book.pending }

    func close() {
        desk.close()
        events.close()
        try? FileManager.default.removeItem(at: dir)
    }

    /// fake-hook.py with this rig's PEEKABOO_DIR.
    func fakeHook(_ args: [String]) throws -> Child {
        try Child(
            "/usr/bin/python3", [repoRoot.appendingPathComponent("scripts/fake-hook.py").path] + args,
            env: ["PEEKABOO_DIR": dir.path, "HOME": dir.path]
        )
    }

    /// The last line of a fixture on its own, for fake-hook.py send.
    func decideLineOnly(_ fixturePath: String) throws -> String {
        let lines = try String(contentsOfFile: fixturePath, encoding: .utf8).split(separator: "\n")
        let url = dir.appendingPathComponent("request.jsonl")
        try Data((try #require(lines.last) + "\n").utf8).write(to: url)
        return url.path
    }

    /// A jsonl in the rig dir, for fake-hook.py send.
    func jsonl(_ name: String, _ objects: [[String: Any]]) throws -> String {
        let url = dir.appendingPathComponent(name)
        var data = Data()
        for obj in objects {
            data += try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
        }
        try data.write(to: url)
        return url.path
    }
}

/// A child process with stdout captured. Polled rather than waited on, so
/// the main actor stays free to run the desk while the child blocks.
private final class Child: @unchecked Sendable {
    let process = Process()
    private let out = Pipe()

    init(_ exe: String, _ args: [String], env: [String: String], stdin: Data? = nil) throws {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = env.merging(["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]) { a, _ in a }
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// Waits for exit, then returns stdout.
    @MainActor
    func output(timeout: TimeInterval = 5) async throws -> String {
        try await waitUntil(timeout: timeout) { !self.process.isRunning }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    func kill() { Darwin.kill(pid, SIGKILL) }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TimedOut() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private struct TimedOut: Error {}

private func stop(_ agent: String) -> Event {
    Event(client: .claude, event: "Stop", agent: agent, ts: nowMs() + 1)
}

private func post(_ agent: String, tool: String, input: JSONValue, ts: Int64) -> Event {
    Event(client: .claude, event: "PostToolUse", agent: agent, ts: ts, tool: tool,
          hook: .object(["tool_input": input]))
}

private let fixtureApproval = fixture("claude-approval.jsonl").path
private let fixtureQuestion = fixture("claude-question.jsonl").path

@Suite @MainActor struct ApprovalDeskTests {
    @Test func notchAllowReachesTheHook() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureApproval])
        try await waitUntil { rig.pending.count == 1 }

        let p = rig.pending[0]
        #expect(p.summary == "Bash npm test")
        #expect(rig.opened == [p])
        // The decide line went through ingest before the prompt opened, so
        // beginPrompt finds the session. (The fixture's PreToolUse can land
        // on either side: it's another socket and an earlier ts.)
        let ingestAt = try #require(rig.log.firstIndex(of: "ingest PermissionRequest"))
        #expect(rig.log.firstIndex(of: "opened") == ingestAt + 1)

        #expect(rig.desk.answer(p.id, .allow) == p)
        #expect(try await hook.output() == "{\"decision\":\"allow\"}\n")
        #expect(rig.pending.isEmpty)
        // Second click, or a click racing the first: nothing more is sent.
        #expect(rig.desk.answer(p.id, .allow) == nil)
        #expect(rig.desk.answer(p.id, .deny(message: nil)) == nil)
    }

    @Test func notchDenyReachesTheHook() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureApproval])
        try await waitUntil { rig.pending.count == 1 }
        _ = rig.desk.answer(rig.pending[0].id, .deny(message: nil))
        #expect(try await hook.output() == "{\"decision\":\"deny\"}\n")
    }

    @Test func terminalAnswerClosesWithoutReply() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureApproval])
        try await waitUntil { rig.pending.count == 1 }
        let p = rig.pending[0]

        // A different command finishing isn't this prompt's answer.
        let other = try rig.fakeHook([
            "event", "--event", "PostToolUse", "--agent", "sess-approval", "--tool", "Bash",
            "--tool-input", #"{"command":"npm run lint","description":"Run the test suite"}"#,
        ])
        _ = try await other.output()
        try await waitUntil { rig.ingested.contains { $0.event == "PostToolUse" } }
        #expect(rig.pending == [p])
        #expect(hook.isRunning)

        // The same call finishing is: the terminal said yes.
        let same = try rig.fakeHook([
            "event", "--event", "PostToolUse", "--agent", "sess-approval", "--tool", "Bash",
            "--tool-input", #"{"command":"npm test","description":"Run the test suite"}"#,
        ])
        _ = try await same.output()
        #expect(try await hook.output() == "<EOF, no reply>\n")
        #expect(rig.pending.isEmpty)
        #expect(rig.ended == [p])
        #expect(rig.desk.answer(p.id, .allow) == nil)
    }

    @Test func terminalAnswerThatBeatsTheDecideLine() async throws {
        let rig = try Rig()
        defer { rig.close() }
        // The PostToolUse is stamped later than the request but gets here
        // first, the way the two sockets can race.
        rig.feed(post("sess-late", tool: "Bash", input: approvalInput, ts: nowMs() + 60_000))
        let line = try rig.jsonl("late.jsonl", [[
            "client": "claude", "event": "PermissionRequest", "agent": "sess-late", "tool": "Bash",
            "want": "decision",
            "hook": ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                     "tool_input": ["command": "npm test", "description": "Run the test suite"]],
        ]])
        let hook = try rig.fakeHook(["send", line])
        // Every other test in this file waits on some rig state before
        // checking the hook's output, which gives the main-actor dispatch
        // a chance to run. This one didn't, so the whole 5s output timeout
        // had to cover process spawn + connect + dispatch with no sync
        // point of its own -- flaky under load. Wait for the thing the test
        // actually cares about (the desk saw the request) first.
        try await waitUntil { rig.ingested.contains { $0.event == "PermissionRequest" } }
        #expect(try await hook.output() == "<EOF, no reply>\n")
        #expect(rig.pending.isEmpty)
        #expect(rig.opened.isEmpty)
    }

    @Test func hookDiesMidWait() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureApproval])
        try await waitUntil { rig.pending.count == 1 }
        let p = rig.pending[0]

        hook.kill()
        try await waitUntil { rig.pending.first?.hookGone == true }
        // Row stays so it can say "answer in terminal", but it can't be answered.
        #expect(rig.pending.count == 1)
        #expect(rig.desk.answer(p.id, .allow) == nil)
        #expect(rig.pending.count == 1)
        #expect(rig.ended.isEmpty)

        // Whatever the terminal did next clears it.
        rig.feed(stop("sess-approval"))
        #expect(rig.pending.isEmpty)
        #expect(rig.ended.map(\.id) == [p.id])
    }

    @Test func answerRacingAHookThatJustDied() async throws {
        // The click lands before the exit watch fires. The write goes to a
        // dead socket and must not take the app down with SIGPIPE.
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureApproval])
        try await waitUntil { rig.pending.count == 1 }
        let id = rig.pending[0].id
        hook.kill()
        while hook.isRunning { usleep(1000) }   // stays on main, so the watch can't fire yet
        #expect(rig.pending.first?.hookGone == false)
        #expect(rig.desk.answer(id, .allow)?.id == id)
        #expect(try await hook.output() == "")
        #expect(rig.pending.isEmpty)
        // Give the canceled watch a moment; nothing should come back.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.pending.isEmpty)
    }

    @Test func identicalRequestsGetTheirOwnReplies() async throws {
        let rig = try Rig()
        defer { rig.close() }
        // Just the decide line: a replayed PreToolUse would (rightly)
        // resolve the first request.
        let request = try rig.decideLineOnly(fixtureApproval)
        let first = try rig.fakeHook(["send", request])
        try await waitUntil { rig.pending.count == 1 }
        let second = try rig.fakeHook(["send", request])
        try await waitUntil { rig.pending.count == 2 }
        let (a, b) = (rig.pending[0], rig.pending[1])
        #expect(a.id != b.id)
        #expect(a.toolInput == b.toolInput)

        _ = rig.desk.answer(b.id, .deny(message: nil))
        #expect(try await second.output() == "{\"decision\":\"deny\"}\n")
        #expect(first.isRunning)
        #expect(rig.pending == [a])

        _ = rig.desk.answer(a.id, .allow)
        #expect(try await first.output() == "{\"decision\":\"allow\"}\n")
    }

    @Test func identicalRequestsBothCloseOnOneTerminalAnswer() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let request = try rig.decideLineOnly(fixtureApproval)
        let first = try rig.fakeHook(["send", request])
        try await waitUntil { rig.pending.count == 1 }
        let second = try rig.fakeHook(["send", request])
        try await waitUntil { rig.pending.count == 2 }

        rig.feed(post("sess-approval", tool: "Bash", input: approvalInput, ts: nowMs() + 1))
        #expect(try await first.output() == "<EOF, no reply>\n")
        #expect(try await second.output() == "<EOF, no reply>\n")
        #expect(rig.ended.count == 2)
    }

    @Test func notOursIsHungUpOn() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let pre = try rig.fakeHook(["event", "--event", "PreToolUse", "--agent", "x", "--decide",
                                    "--tool", "Bash", "--tool-input", #"{"command":"ls"}"#])
        let codex = try rig.fakeHook(["event", "--event", "PermissionRequest", "--agent", "y",
                                      "--client", "codex", "--decide",
                                      "--tool", "Bash", "--tool-input", #"{"command":"ls"}"#])
        // No `hook` at all, so nothing to show.
        let bare = try rig.fakeHook(["event", "--event", "PermissionRequest", "--agent", "z",
                                     "--decide", "--tool", "Bash"])
        #expect(try await pre.output() == "<EOF, no reply>\n")
        #expect(try await codex.output() == "<EOF, no reply>\n")
        #expect(try await bare.output() == "<EOF, no reply>\n")
        #expect(rig.pending.isEmpty)
        #expect(rig.opened.isEmpty)
        // Only the Claude PermissionRequest counts as an event from here.
        #expect(rig.ingested.map(\.agent) == ["z"])
    }

    @Test func questionFixtureOpensAndAnswers() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureQuestion])
        try await waitUntil { rig.pending.count == 1 }
        let p = rig.pending[0]
        let qs = try #require(p.questions)
        #expect(qs.map(\.header) == ["Cache", "Envs"])
        #expect(qs.map(\.multiSelect) == [false, true])
        #expect(p.summary == "Which database should the cache use?")

        let message = Question.answerMessage(qs, answers: [["Redis"], ["dev", "prod"]])
        _ = rig.desk.answer(p.id, .deny(message: message))
        let reply = try await hook.output()
        let obj = try #require(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String]
        )
        #expect(obj["decision"] == "deny")
        #expect(obj["message"] == #"User has answered your questions: "Which database should the cache use?"="Redis", "Which environments get it?"="dev, prod". You can now continue with the user's answers in mind."#)
    }

    @Test func typedAnswerSentOnceReachesTheHook() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureQuestion])
        try await waitUntil { rig.pending.count == 1 }
        let p = rig.pending[0]
        let qs = try #require(p.questions)

        let message = Question.answerMessage(qs, answers: [[], []], typed: [0: "something else"])
        #expect(rig.desk.answer(p.id, .deny(message: message)) == p)
        let reply = try await hook.output()
        let obj = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: String])
        #expect(obj["message"]?.contains(#""something else""#) == true)

        // Second send, or a click racing the first: nothing more goes out.
        #expect(rig.desk.answer(p.id, .deny(message: message)) == nil)
        #expect(rig.desk.answer(p.id, .allow) == nil)
    }

    @Test func typedAnswerNeverSentAfterTheTerminalAnswers() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let hook = try rig.fakeHook(["send", fixtureQuestion])
        try await waitUntil { rig.pending.count == 1 }
        let p = rig.pending[0]

        // The terminal answered first: Stop resolves the prompt before the
        // notch's Send got clicked.
        rig.feed(stop("sess-question"))
        #expect(rig.pending.isEmpty)
        #expect(try await hook.output() == "<EOF, no reply>\n")

        let qs = try #require(p.questions)
        let message = Question.answerMessage(qs, answers: [[], []], typed: [0: "too late"])
        #expect(rig.desk.answer(p.id, .deny(message: message)) == nil)
    }

    // MARK: the real hook

    @Test func realHookGetsAllow() async throws {
        let bin = try await builtHook()
        let rig = try Rig()
        defer { rig.close() }
        let hook = try realHook(bin, rig, payload(fixtureApproval))
        try await waitUntil { rig.pending.count == 1 }
        #expect(rig.pending[0].key.agent == "sess-approval")
        // term.pid is us: the hook's parent isn't a shell.
        #expect(rig.ingested.last?.term.pid == getpid())
        _ = rig.desk.answer(rig.pending[0].id, .allow)
        #expect(try await hook.output() ==
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"# + "\n")
        #expect(hook.process.terminationStatus == 0)
    }

    @Test func realHookGetsBareDeny() async throws {
        let bin = try await builtHook()
        let rig = try Rig()
        defer { rig.close() }
        let hook = try realHook(bin, rig, payload(fixtureApproval))
        try await waitUntil { rig.pending.count == 1 }
        _ = rig.desk.answer(rig.pending[0].id, .deny(message: nil))
        #expect(try await hook.output() ==
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from peek-ai-boo."}}}"# + "\n")
    }

    @Test func realHookGetsQuestionAnswers() async throws {
        let bin = try await builtHook()
        let full = try payload(fixtureQuestion)
        let input = try #require(full["tool_input"] as? [String: Any])
        let rawQuestions = try #require(input["questions"] as? [Any])
        let questions = try #require(Question.parse(JSONValue.parse(JSONSerialization.data(withJSONObject: input))))
        var single = full
        single["tool_input"] = ["questions": [rawQuestions[0]]]

        let cases: [(input: [String: Any], qs: [Question], answers: [[String]], expected: String)] = [
            (single, [questions[0]], [["Postgres"]],
             #"User has answered your questions: "Which database should the cache use?"="Postgres". You can now continue with the user's answers in mind."#),
            (full, questions, [["Redis"], ["preview"]],
             #"User has answered your questions: "Which database should the cache use?"="Redis", "Which environments get it?"="preview". You can now continue with the user's answers in mind."#),
            (full, questions, [["Postgres"], ["dev", "preview", "prod"]],
             #"User has answered your questions: "Which database should the cache use?"="Postgres", "Which environments get it?"="dev, preview, prod". You can now continue with the user's answers in mind."#),
        ]
        for c in cases {
            let rig = try Rig()
            defer { rig.close() }
            let hook = try realHook(bin, rig, c.input)
            try await waitUntil { rig.pending.count == 1 }
            #expect(rig.pending[0].questions == c.qs)
            let message = Question.answerMessage(c.qs, answers: c.answers)
            _ = rig.desk.answer(rig.pending[0].id, .deny(message: message))
            let out = try await hook.output()
            #expect(out.hasSuffix("}\n"))
            let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            let decision = (obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: String]
            #expect(decision == ["behavior": "deny", "message": c.expected])
        }
    }

    @Test func realHookExitsQuietlyWhenTheTerminalAnswers() async throws {
        let bin = try await builtHook()
        let rig = try Rig()
        defer { rig.close() }
        let hook = try realHook(bin, rig, payload(fixtureApproval))
        try await waitUntil { rig.pending.count == 1 }
        rig.feed(post("sess-approval", tool: "Bash", input: approvalInput, ts: nowMs() + 1))
        #expect(try await hook.output() == "")
        #expect(hook.process.terminationStatus == 0)
        #expect(rig.pending.isEmpty)
    }

    @Test func realHookKilledMidWait() async throws {
        let bin = try await builtHook()
        let rig = try Rig()
        defer { rig.close() }
        let hook = try realHook(bin, rig, payload(fixtureApproval))
        try await waitUntil { rig.pending.count == 1 }
        hook.kill()
        try await waitUntil { rig.pending.first?.hookGone == true }
        #expect(rig.desk.answer(rig.pending[0].id, .allow) == nil)
    }
}

// MARK: real hook helpers

/// The raw Claude payload behind a fixture's decide line. The fixtures are
/// small enough that the size pass leaves `hook` untouched.
private func payload(_ path: String) throws -> [String: Any] {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    let last = try #require(lines.last)
    let obj = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
    return try #require(obj["hook"] as? [String: Any])
}

@MainActor
private func realHook(_ bin: String, _ rig: Rig, _ payload: [String: Any]) throws -> Child {
    try Child(bin, ["--client", "claude"],
              env: ["PEEKABOO_DIR": rig.dir.path, "HOME": rig.dir.path],
              stdin: try JSONSerialization.data(withJSONObject: payload))
}

/// make -C hook once per test run, off the main actor.
private let hookBuild = Task.detached { () -> Result<String, BuildFailed> in
    let make = Process()
    make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
    make.arguments = ["-s", "-C", repoRoot.appendingPathComponent("hook").path]
    make.standardOutput = FileHandle.nullDevice
    make.standardError = FileHandle.nullDevice
    do { try make.run() } catch { return .failure(BuildFailed()) }
    make.waitUntilExit()
    guard make.terminationStatus == 0 else { return .failure(BuildFailed()) }
    return .success(repoRoot.appendingPathComponent("hook/.build/peekaboo-hook").path)
}

private struct BuildFailed: Error {}

private func builtHook() async throws -> String {
    try await hookBuild.value.get()
}
