import Foundation

public enum Client: String, Sendable, Hashable, CaseIterable {
    case claude, codex
}

public struct SessionKey: Hashable, Sendable {
    public let client: Client
    public let agent: String
    public init(client: Client, agent: String) {
        self.client = client
        self.agent = agent
    }
}

public struct Term: Sendable, Equatable {
    public var pid: Int32?
    public var tty, program, cmuxSurface, cmuxWorkspace, cmuxSocket, cmuxCli: String?

    public init(
        pid: Int32? = nil, tty: String? = nil, program: String? = nil,
        cmuxSurface: String? = nil, cmuxWorkspace: String? = nil,
        cmuxSocket: String? = nil, cmuxCli: String? = nil
    ) {
        self.pid = pid
        self.tty = tty
        self.program = program
        self.cmuxSurface = cmuxSurface
        self.cmuxWorkspace = cmuxWorkspace
        self.cmuxSocket = cmuxSocket
        self.cmuxCli = cmuxCli
    }
}

public struct Event: Sendable, Equatable {
    public var client: Client
    public var event: String
    public var agent: String
    public var verb, path, want, tool, toolUseID, promptID, cwd, transcript: String?
    public var ts: Int64
    public var term: Term
    public var trunc: Bool
    public var hook: JSONValue?

    public init(
        client: Client, event: String, agent: String, ts: Int64,
        verb: String? = nil, path: String? = nil, want: String? = nil,
        tool: String? = nil, toolUseID: String? = nil, promptID: String? = nil,
        cwd: String? = nil, transcript: String? = nil, term: Term = Term(),
        trunc: Bool = false, hook: JSONValue? = nil
    ) {
        self.client = client
        self.event = event
        self.agent = agent
        self.ts = ts
        self.verb = verb
        self.path = path
        self.want = want
        self.tool = tool
        self.toolUseID = toolUseID
        self.promptID = promptID
        self.cwd = cwd
        self.transcript = transcript
        self.term = term
        self.trunc = trunc
        self.hook = hook
    }

    public var key: SessionKey { SessionKey(client: client, agent: agent) }
    public var toolInput: JSONValue? { hook?["tool_input"] }
    public var wantsDecision: Bool { want == "decision" }

    /// nil for bad JSON, v != 1, unknown client, empty agent, missing event or ts.
    public static func parse(_ line: Data) -> Event? {
        guard let json = JSONValue.parse(line), case .object = json else { return nil }
        guard json["v"]?.intValue == 1 else { return nil }
        guard let clientStr = json["client"]?.stringValue,
              let client = Client(rawValue: clientStr) else { return nil }
        guard let agent = json["agent"]?.stringValue, !agent.isEmpty else { return nil }
        guard let event = json["event"]?.stringValue else { return nil }
        guard let ts = json["ts"]?.intValue else { return nil }

        var term = Term()
        if let t = json["term"] {
            term.pid = t["pid"]?.intValue.map { Int32($0) }
            term.tty = t["tty"]?.stringValue
            term.program = t["program"]?.stringValue
            term.cmuxSurface = t["cmux_surface"]?.stringValue
            term.cmuxWorkspace = t["cmux_workspace"]?.stringValue
            term.cmuxSocket = t["cmux_socket"]?.stringValue
            term.cmuxCli = t["cmux_cli"]?.stringValue
        }

        return Event(
            client: client, event: event, agent: agent, ts: Int64(ts),
            verb: json["verb"]?.stringValue,
            path: json["path"]?.stringValue,
            want: json["want"]?.stringValue,
            tool: json["tool"]?.stringValue,
            toolUseID: json["tool_use_id"]?.stringValue,
            promptID: json["prompt_id"]?.stringValue,
            cwd: json["cwd"]?.stringValue,
            transcript: json["transcript"]?.stringValue,
            term: term,
            trunc: json["trunc"]?.boolValue ?? false,
            hook: json["hook"]
        )
    }

    /// What the app feeds itself when term.pid exits.
    public static func sessionEnd(_ key: SessionKey, ts: Int64) -> Event {
        Event(client: key.client, event: "SessionEnd", agent: key.agent, ts: ts)
    }
}

public func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
