import Foundation
import Testing
@testable import PeekCore

@Suite struct InstallerTests {
    /// Not the real CodexHooks (that's feat/codex's), just enough of a
    /// second client to exercise "config file doesn't exist yet".
    private static let fakeCodexSpec = HookSpec(
        client: .codex, configPath: ".codex/hooks.json",
        events: [HookEvent("SessionStart", timeout: 5)])

    private func makeHome() throws -> String {
        try shortTempDir().path
    }

    private func writeClaudeSettings(home: String, mode: Int = 0o600) throws -> String {
        let dir = home + "/.claude"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/settings.json"
        let data = try Data(contentsOf: fixture("settings-foreign-hooks.json"))
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    private func makeHookSource() throws -> String {
        let dir = try shortTempDir().path
        let path = dir + "/fake-hook"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func jsonEqual(_ a: Data, _ b: Data) throws -> Bool {
        let oa = try JSONSerialization.jsonObject(with: a) as! [String: Any]
        let ob = try JSONSerialization.jsonObject(with: b) as! [String: Any]
        let da = try JSONSerialization.data(withJSONObject: oa, options: [.sortedKeys])
        let db = try JSONSerialization.data(withJSONObject: ob, options: [.sortedKeys])
        return da == db
    }

    private func mode(_ path: String) throws -> Int {
        let n = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
        return n.intValue
    }

    @Test func installMergesHookAndBacksUp() throws {
        let home = try makeHome()
        let settingsPath = try writeClaudeSettings(home: home)
        let original = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(),
            specs: [ClaudeHooks.spec, Self.fakeCodexSpec])

        let lines = try installer.install()
        #expect(lines.contains { $0.contains(".claude/settings.json") })
        #expect(!lines.contains { $0.contains("codex") })  // .codex doesn't exist: skipped

        // backup holds the pristine original
        let backups = try FileManager.default.contentsOfDirectory(atPath: home + "/.claude")
            .filter { $0.hasPrefix("settings.json.peek-ai-boo.") && $0.hasSuffix(".bak") }
        #expect(backups.count == 1)
        let backupData = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude/" + backups[0]))
        #expect(backupData == original)

        // foreign hooks and our hook both present
        let merged = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let root = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let preToolUse = hooks["PreToolUse"] as! [[String: Any]]
        #expect(preToolUse.contains { ($0["matcher"] as? String) == "Bash" })
        #expect(preToolUse.contains { group in
            let entries = group["hooks"] as? [[String: Any]] ?? []
            return entries.contains { HookConfig.isOurs($0["command"] as? String ?? "") }
        })

        // hook binary landed, executable
        #expect(FileManager.default.fileExists(atPath: paths.hookBinary))
        #expect(try mode(paths.hookBinary) == 0o755)
    }

    @Test func installTwiceIsIdempotent() throws {
        let home = try makeHome()
        _ = try writeClaudeSettings(home: home)
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(), specs: [ClaudeHooks.spec])

        _ = try installer.install()
        let afterFirst = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude/settings.json"))
        _ = try installer.install()
        let afterSecond = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude/settings.json"))
        #expect(afterFirst == afterSecond)
    }

    @Test func uninstallDropsOursKeepsForeign() throws {
        let home = try makeHome()
        let settingsPath = try writeClaudeSettings(home: home)
        let original = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(), specs: [ClaudeHooks.spec])

        _ = try installer.install()
        let lines = try installer.uninstall()
        #expect(lines.contains { $0.contains(".claude/settings.json") })

        let restored = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        #expect(try jsonEqual(restored, original))
    }

    @Test func missingParentDirIsSkippedEntirely() throws {
        let home = try makeHome()
        _ = try writeClaudeSettings(home: home)
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(),
            specs: [Self.fakeCodexSpec])  // no ~/.codex at all

        let lines = try installer.install()
        #expect(lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home + "/.codex"))
    }

    @Test func uninstallNeverCreatesAMissingFile() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(),
            specs: [Self.fakeCodexSpec])  // .codex exists, hooks.json does not

        let lines = try installer.uninstall()
        #expect(lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home + "/.codex/hooks.json"))
    }

    @Test func brokenJSONThrowsAndLeavesFileAlone() throws {
        let home = try makeHome()
        let dir = home + "/.claude"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/settings.json"
        let broken = Data("{not json".utf8)
        try broken.write(to: URL(fileURLWithPath: path))
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(), specs: [ClaudeHooks.spec])

        #expect(throws: (any Error).self) { try installer.install() }
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(after == broken)
    }

    @Test func hookPathWithSpaceThrows() throws {
        let home = try makeHome()
        _ = try writeClaudeSettings(home: home)
        let paths = Paths(dir: home + "/peek ai boo")  // space forces the throw
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(), specs: [ClaudeHooks.spec])

        #expect(throws: (any Error).self) { try installer.install() }
        #expect(!FileManager.default.fileExists(atPath: paths.hookBinary))
        // settings.json untouched: install bailed before touching any config file
        let after = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude/settings.json"))
        let before = try Data(contentsOf: fixture("settings-foreign-hooks.json"))
        #expect(after == before)
    }

    @Test func filePermissionsSurviveInstallAndUninstall() throws {
        let home = try makeHome()
        let settingsPath = try writeClaudeSettings(home: home, mode: 0o600)
        let paths = Paths(dir: home + "/.peek-ai-boo")
        let installer = Installer(
            home: home, paths: paths, hookSource: try makeHookSource(), specs: [ClaudeHooks.spec])

        _ = try installer.install()
        #expect(try mode(settingsPath) == 0o600)
        _ = try installer.uninstall()
        #expect(try mode(settingsPath) == 0o600)
    }
}
