import Foundation

/// Reads token totals out of a Codex rollout file. Only `event_msg` lines
/// with `payload.type == "token_count"` carry usage; everything else,
/// including a null `info` (happens before the first turn settles), is
/// skipped. The latest line wins, matching how the rollout accumulates.
public struct CodexUsage: UsageReader {
    private var total: Int?
    private var context: Int?

    public init() {}

    /// event.transcript first (the hook sends it straight from
    /// transcript_path). Falling back to a glob only matters when that's
    /// missing: newest day under sessions/ first, first file whose name ends
    /// in the session id.
    public func transcriptPath(for event: Event, home: String) -> String? {
        if let transcript = event.transcript { return transcript }

        let fm = FileManager.default
        let sessionsDir = URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions")
        let suffix = "-\(event.agent).jsonl"

        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return nil }
        for year in years.sorted(by: >) {
            let yearDir = sessionsDir.appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearDir.path) else { continue }
            for month in months.sorted(by: >) {
                let monthDir = yearDir.appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
                for day in days.sorted(by: >) {
                    let dayDir = monthDir.appendingPathComponent(day)
                    guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
                    if let match = files.first(where: { $0.hasPrefix("rollout-") && $0.hasSuffix(suffix) }) {
                        return dayDir.appendingPathComponent(match).path
                    }
                }
            }
        }
        return nil
    }

    public mutating func feed(_ line: Data) {
        guard let json = JSONValue.parse(line),
              json["type"]?.stringValue == "event_msg",
              let payload = json["payload"],
              payload["type"]?.stringValue == "token_count",
              let total = payload["info"]?["total_token_usage"]?["total_tokens"]?.intValue
        else { return }
        self.total = total
        self.context = payload["info"]?["last_token_usage"]?["input_tokens"]?.intValue ?? 0
    }

    public var usage: Usage? {
        guard let total else { return nil }
        return Usage(total: total, context: context ?? 0)
    }
}
