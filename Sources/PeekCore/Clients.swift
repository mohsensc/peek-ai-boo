import Foundation

public struct HookEvent: Sendable, Equatable {
    public var name: String
    public var timeout: Int
    /// "*" for tool events, nil for the rest (key left out).
    public var matcher: String?
    public init(_ name: String, timeout: Int, matcher: String? = nil) {
        self.name = name; self.timeout = timeout; self.matcher = matcher
    }
}

public struct HookSpec: Sendable, Equatable {
    public var client: Client
    /// Relative to $HOME, e.g. ".claude/settings.json".
    public var configPath: String
    public var events: [HookEvent]
    /// Printed after install or uninstall touches this file.
    public var afterChange: String?
    public init(client: Client, configPath: String, events: [HookEvent], afterChange: String? = nil) {
        self.client = client; self.configPath = configPath
        self.events = events; self.afterChange = afterChange
    }
}

/// Turns one client's transcript lines into token counts.
public protocol UsageReader: Sendable {
    /// Where this session's transcript is.
    func transcriptPath(for event: Event, home: String) -> String?
    /// Complete lines, in file order, no trailing newline.
    mutating func feed(_ line: Data)
    var usage: Usage? { get }
}

extension UsageReader {
    public func transcriptPath(for event: Event, home: String) -> String? { event.transcript }
}

/// Per-client pieces that different PRs provide.
/// Blank lines between entries keep parallel PRs from conflicting.
public enum Clients {
    public static func hookSpecs() -> [HookSpec] {
        var specs: [HookSpec] = []
        specs.append(ClaudeHooks.spec)

        specs.append(CodexHooks.spec)

        return specs
    }

    public static func usageReader(for client: Client) -> (any UsageReader)? {
        var readers: [Client: any UsageReader] = [:]
        // slot: feat/usage

        readers[.codex] = CodexUsage()

        return readers[client]
    }
}
