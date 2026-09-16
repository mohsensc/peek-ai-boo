import Foundation

public struct Paths: Sendable, Equatable {
    public let dir: String

    public init(dir: String) {
        self.dir = dir
    }

    public var events: String { dir + "/events.sock" }
    public var decide: String { dir + "/decide.sock" }
    public var hookBinary: String { dir + "/bin/peekaboo-hook" }

    /// $PEEKABOO_DIR, else $HOME/.peek-ai-boo. Reads $HOME from the
    /// environment on purpose (NSHomeDirectory ignores it), so tests can sandbox.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let dir = env["PEEKABOO_DIR"], !dir.isEmpty {
            return Paths(dir: dir)
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        return Paths(dir: home + "/.peek-ai-boo")
    }

    /// mkdir -p, chmod 0700.
    public func ensureDir() throws {
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    }
}
