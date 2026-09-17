import Foundation

/// Follows a growing file, handing back only what's new since the last
/// call. Built for transcript JSONL files that get one line appended per
/// turn, read again after every hook event instead of on a timer.
public struct TranscriptTail: Sendable {
    private let path: String
    private var offset: UInt64 = 0
    private var held = Data()

    public init(path: String) {
        self.path = path
    }

    /// Complete new lines since the last call. Keeps a partial last line for
    /// next time. If the file shrank, starts over from 0 and says so.
    public mutating func read() throws -> (lines: [Data], restarted: Bool) {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? UInt64) ?? 0

        let restarted = size < offset
        if restarted {
            offset = 0
            held = Data()
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ([], restarted)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let newData = handle.readDataToEndOfFile()
        offset += UInt64(newData.count)

        var combined = held
        combined.append(newData)

        var lines: [Data] = []
        var lineStart = combined.startIndex
        var i = combined.startIndex
        while i < combined.endIndex {
            if combined[i] == 0x0A {
                lines.append(Data(combined[lineStart..<i]))
                lineStart = combined.index(after: i)
            }
            i = combined.index(after: i)
        }
        held = Data(combined[lineStart...])

        return (lines, restarted)
    }
}
