/// Turns a tool call into one line for a session row.
public enum ToolSummary {
    /// "Bash npm test", "Edit Sources/x.swift" (relative when under cwd),
    /// "WebFetch https://...", "Grep pattern". One line, max 60 chars.
    public static func make(tool: String?, input: JSONValue?, cwd: String?) -> String? {
        guard let tool, !tool.isEmpty else { return nil }

        let detail: String?
        switch tool {
        case "Bash":
            detail = input?["command"]?.stringValue
        case "Edit", "Write", "MultiEdit":
            detail = relative(input?["file_path"]?.stringValue, cwd: cwd)
        case "NotebookEdit":
            detail = relative(input?["notebook_path"]?.stringValue, cwd: cwd)
        case "Read":
            detail = relative(input?["file_path"]?.stringValue, cwd: cwd)
        case "Grep", "Glob":
            detail = input?["pattern"]?.stringValue
        case "WebFetch":
            detail = input?["url"]?.stringValue
        default:
            detail = relative(input?["file_path"]?.stringValue ?? input?["path"]?.stringValue, cwd: cwd)
        }

        let line = detail.map { "\(tool) \($0)" } ?? tool
        return line.count > 60 ? String(line.prefix(60)) : line
    }

    /// Drops the cwd prefix so long paths read like a person wrote them.
    private static func relative(_ path: String?, cwd: String?) -> String? {
        guard let path else { return nil }
        guard let cwd, !cwd.isEmpty else { return path }
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
