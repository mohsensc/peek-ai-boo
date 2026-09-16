import Foundation
import Testing
@testable import PeekCore

@Suite struct TranscriptTailTests {
    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @Test func partialLineHeldUntilTheNewlineLands() throws {
        let path = try shortTempDir().appendingPathComponent("t.jsonl").path
        try write("line one\npartial", to: path)

        var tail = TranscriptTail(path: path)
        var result = try tail.read()
        #expect(result.lines == [Data("line one".utf8)])
        #expect(result.restarted == false)

        // Nothing new landed: the partial line stays held, not re-reported.
        result = try tail.read()
        #expect(result.lines.isEmpty)

        // The rest of that line arrives, plus a newline to close it.
        try write("line one\npartial line two\n", to: path)
        result = try tail.read()
        #expect(result.lines == [Data("partial line two".utf8)])
    }

    @Test func appendsAreOnlyReadOnce() throws {
        let path = try shortTempDir().appendingPathComponent("t.jsonl").path
        try write("a\n", to: path)

        var tail = TranscriptTail(path: path)
        #expect(try tail.read().lines == [Data("a".utf8)])
        #expect(try tail.read().lines.isEmpty)

        try write("a\nb\n", to: path)
        #expect(try tail.read().lines == [Data("b".utf8)])

        try write("a\nb\nc\nd\n", to: path)
        #expect(try tail.read().lines == [Data("c".utf8), Data("d".utf8)])
    }

    @Test func fileShrinkingRestartsFromZero() throws {
        let path = try shortTempDir().appendingPathComponent("t.jsonl").path
        try write("one\ntwo\n", to: path)

        var tail = TranscriptTail(path: path)
        let first = try tail.read()
        #expect(first.lines == [Data("one".utf8), Data("two".utf8)])
        #expect(first.restarted == false)

        // A rotated or truncated log: shorter than what we'd already read.
        try write("x\n", to: path)
        let second = try tail.read()
        #expect(second.restarted == true)
        #expect(second.lines == [Data("x".utf8)])
    }
}
