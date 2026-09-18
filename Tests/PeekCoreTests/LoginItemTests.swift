import Foundation
import Testing
@testable import PeekCore

@Suite struct LoginItemTests {
    @Test func installWritesAWellFormedPlist() throws {
        let home = try shortTempDir().path
        let line = try LoginItem.install(home: home, programPath: "/Applications/PeekAiBoo.app/Contents/MacOS/PeekAiBoo")
        #expect(line.contains("Library/LaunchAgents"))

        let path = LoginItem.plistPath(home: home)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        #expect(plist["Label"] as? String == LoginItem.label)
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/PeekAiBoo.app/Contents/MacOS/PeekAiBoo"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        let keepAlive = plist["KeepAlive"] as? [String: Any]
        #expect(keepAlive?["SuccessfulExit"] as? Bool == false)
    }

    @Test func installTwiceIsIdempotent() throws {
        let home = try shortTempDir().path
        _ = try LoginItem.install(home: home, programPath: "/a/PeekAiBoo")
        let first = try Data(contentsOf: URL(fileURLWithPath: LoginItem.plistPath(home: home)))
        _ = try LoginItem.install(home: home, programPath: "/a/PeekAiBoo")
        let second = try Data(contentsOf: URL(fileURLWithPath: LoginItem.plistPath(home: home)))
        #expect(first == second)
    }

    @Test func uninstallRemovesThePlist() throws {
        let home = try shortTempDir().path
        _ = try LoginItem.install(home: home, programPath: "/a/PeekAiBoo")
        let line = try LoginItem.uninstall(home: home)
        #expect(line != nil)
        #expect(!FileManager.default.fileExists(atPath: LoginItem.plistPath(home: home)))
    }

    @Test func uninstallOnNothingIsANoOp() throws {
        let home = try shortTempDir().path
        let line = try LoginItem.uninstall(home: home)
        #expect(line == nil)
    }
}
