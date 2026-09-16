import Foundation
import Testing
@testable import PeekCore

@Suite struct PathsTests {
    @Test func peekabooDirWins() {
        let paths = Paths.fromEnvironment(["PEEKABOO_DIR": "/tmp/x", "HOME": "/Users/m"])
        #expect(paths.dir == "/tmp/x")
        #expect(paths.events == "/tmp/x/events.sock")
        #expect(paths.decide == "/tmp/x/decide.sock")
        #expect(paths.hookBinary == "/tmp/x/bin/peekaboo-hook")
    }

    @Test func homeFallback() {
        let paths = Paths.fromEnvironment(["HOME": "/Users/m"])
        #expect(paths.dir == "/Users/m/.peek-ai-boo")
    }

    @Test func ensureDirSets0700() throws {
        let dir = try shortTempDir().appendingPathComponent("nested").path
        let paths = Paths(dir: dir)
        try paths.ensureDir()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o700)
    }
}
