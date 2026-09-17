import Foundation
import Testing
@testable import PeekCore

@Suite struct HookConfigTests {
    @Test func isOurs() {
        #expect(HookConfig.isOurs("/x/peekaboo-hook --client claude"))
        #expect(!HookConfig.isOurs("peekaboo-hook-old"))
        #expect(HookConfig.isOurs("/x/peekaboo-hook"))
        #expect(!HookConfig.isOurs("echo /x/peekaboo-hook"))
    }

    private func fixtureRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: fixture("settings-foreign-hooks.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func jsonEqual(_ a: [String: Any], _ b: [String: Any]) throws -> Bool {
        let da = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let db = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        return da == db
    }

    @Test func addOursTwiceIsSameBytes() throws {
        let root = try fixtureRoot()
        let once = HookConfig.addOurs(to: root, spec: ClaudeHooks.spec, hookPath: "/x/peekaboo-hook")
        let twice = HookConfig.addOurs(to: once, spec: ClaudeHooks.spec, hookPath: "/x/peekaboo-hook")
        #expect(try HookConfig.encode(once) == HookConfig.encode(twice))
    }

    @Test func foreignHooksSurviveInSameEventAndGroup() throws {
        let root = try fixtureRoot()
        let merged = HookConfig.addOurs(to: root, spec: ClaudeHooks.spec, hookPath: "/x/peekaboo-hook")
        let preToolUse = merged["hooks"] as? [String: Any]
        let groups = preToolUse?["PreToolUse"] as? [[String: Any]]
        #expect(groups?.count == 3)  // 2 foreign groups plus ours

        let bashGroup = groups?.first { ($0["matcher"] as? String) == "Bash" }
        let bashHooks = bashGroup?["hooks"] as? [[String: Any]]
        #expect(bashHooks?.count == 1)
        #expect((bashHooks?.first?["command"] as? String)?.contains("check-branch-policy.sh") == true)

        let devtoolGroup = groups?.first { ($0["matcher"] as? String) == "mcp__some-devtool__.*" }
        #expect(devtoolGroup != nil)
    }

    @Test func removeAfterAddRoundTripsFixture() throws {
        let root = try fixtureRoot()
        let merged = HookConfig.addOurs(to: root, spec: ClaudeHooks.spec, hookPath: "/x/peekaboo-hook")
        let restored = HookConfig.removeOurs(from: merged)
        #expect(try jsonEqual(restored, root))
    }

    @Test func removeAfterAddRoundTripsEmptyRoot() throws {
        let root: [String: Any] = [:]
        let merged = HookConfig.addOurs(to: root, spec: ClaudeHooks.spec, hookPath: "/x/peekaboo-hook")
        let restored = HookConfig.removeOurs(from: merged)
        #expect(try jsonEqual(restored, root))
    }

    @Test func timeoutsAndMatchersPerEvent() {
        let root = HookConfig.addOurs(to: [:], spec: ClaudeHooks.spec, hookPath: "/x/peekaboo-hook")
        let hooks = root["hooks"] as! [String: Any]

        func firstEntry(_ event: String) -> [String: Any] {
            let groups = hooks[event] as! [[String: Any]]
            #expect(groups.count == 1)
            let entries = groups[0]["hooks"] as! [[String: Any]]
            return entries[0]
        }

        let permissionRequest = firstEntry("PermissionRequest")
        #expect(permissionRequest["timeout"] as? Int == 3600)
        #expect((hooks["PermissionRequest"] as! [[String: Any]])[0]["matcher"] as? String == "*")

        let sessionStart = firstEntry("SessionStart")
        #expect(sessionStart["timeout"] as? Int == 5)
        #expect((hooks["SessionStart"] as! [[String: Any]])[0]["matcher"] == nil)

        let preToolUse = firstEntry("PreToolUse")
        #expect(preToolUse["timeout"] as? Int == 5)
        #expect((hooks["PreToolUse"] as! [[String: Any]])[0]["matcher"] as? String == "*")

        #expect(hooks.count == 12)
    }
}
