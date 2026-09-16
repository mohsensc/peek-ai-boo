import Foundation

/// What the app writes back on a decide connection. The hook turns it into
/// Claude's hookSpecificOutput, copying `message` as the raw JSON token.
public enum DecideReply: Sendable, Equatable {
    case allow
    case deny(message: String?)

    /// One JSON object, no trailing newline (LineConnection.reply adds it).
    public var line: Data {
        var obj = ["decision": "allow"]
        if case .deny(let message) = self {
            obj["decision"] = "deny"
            obj["message"] = message
        }
        // sortedKeys keeps the bytes stable and happens to put decision
        // first. A string-only dictionary can't fail to serialize.
        return try! JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
