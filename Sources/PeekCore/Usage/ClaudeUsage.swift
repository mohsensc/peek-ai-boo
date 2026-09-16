import Foundation

/// Turns a Claude transcript's assistant lines into a running token count.
/// Usage is repeated on every content-block line of the same message, so
/// only the per-id total is kept, last write wins.
public struct ClaudeUsage: UsageReader {
    private var totalByMessageID: [String: Int] = [:]
    private var lastContext: Int?

    public init() {}

    public mutating func feed(_ line: Data) {
        guard let json = JSONValue.parse(line),
              json["type"]?.stringValue == "assistant",
              let message = json["message"],
              let id = message["id"]?.stringValue,
              let usage = message["usage"]
        else { return }

        let input = usage["input_tokens"]?.intValue ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"]?.intValue ?? 0
        let cacheRead = usage["cache_read_input_tokens"]?.intValue ?? 0
        let output = usage["output_tokens"]?.intValue ?? 0

        totalByMessageID[id] = input + cacheCreation + cacheRead + output
        lastContext = input + cacheCreation + cacheRead
    }

    public var usage: Usage? {
        guard let lastContext else { return nil }
        return Usage(total: totalByMessageID.values.reduce(0, +), context: lastContext)
    }
}
