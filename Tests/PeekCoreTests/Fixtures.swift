import Foundation

/// Repo root, found from this file so tests don't depend on the cwd.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // PeekCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()

func fixture(_ name: String) -> URL {
    repoRoot.appendingPathComponent("fixtures").appendingPathComponent(name)
}

/// A short temp dir for sockets. AF_UNIX paths cap near 104 bytes, and
/// $TMPDIR here is ~50, which leaves room.
func shortTempDir() throws -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
    var template = Array((base + "pab.XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { throw CocoaError(.fileWriteUnknown) }
    return URL(fileURLWithPath: String(cString: template))
}
