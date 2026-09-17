import Foundation
import Testing
@testable import PeekCore

@Suite struct ClaudeUsageTests {
    /// fixtures/claude-transcript.jsonl, split back into its raw lines. The
    /// file ends without a trailing newline on purpose (a write cut mid
    /// line), so this yields exactly 7 lines, the last one truncated JSON.
    static func lines() throws -> [Data] {
        let text = try String(contentsOf: fixture("claude-transcript.jsonl"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { Data($0.utf8) }
    }

    @Test func emptyReaderHasNoUsage() {
        #expect(ClaudeUsage().usage == nil)
    }

    @Test func nonAssistantLinesAreIgnored() throws {
        var usage = ClaudeUsage()
        let all = try Self.lines()
        usage.feed(all[0])  // user
        usage.feed(all[1])  // system, no usage field
        #expect(usage.usage == nil)
    }

    @Test func repeatedContentBlocksCountTheMessageOnce() throws {
        var usage = ClaudeUsage()
        for line in try Self.lines() { usage.feed(line) }
        // msg_a repeats its usage across 3 content-block lines (115 once,
        // not 3x); msg_b adds 78. A dedup bug would show up as 423 or 193+230.
        #expect(usage.usage?.total == 193)
    }

    @Test func contextComesFromTheLastMessage() throws {
        var usage = ClaudeUsage()
        for line in try Self.lines() { usage.feed(line) }
        // msg_b's input + cache_creation + cache_read (20 + 0 + 50), not msg_a's.
        #expect(usage.usage?.context == 70)
    }

    @Test func truncatedTrailingLineIsIgnored() throws {
        var usage = ClaudeUsage()
        let all = try Self.lines()
        for line in all { usage.feed(line) }
        // The cut-off msg_c line never parses as JSON, so totals and
        // context still reflect the last complete message, msg_b.
        #expect(usage.usage?.total == 193)
        #expect(usage.usage?.context == 70)
    }
}
