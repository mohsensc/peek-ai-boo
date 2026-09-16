import Foundation

/// AppleScript source for terminal-jump. Just string building; running it is
/// TerminalJump's job, off the main thread.
public enum AppleScriptText {
    /// `"..."` with `\` and `"` escaped, for splicing into a script literal.
    public static func quoted(_ s: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(s.count + 2)
        for ch in s {
            if ch == "\\" || ch == "\"" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// Ghostty 1.3's own dictionary: terminals are elements of the app,
    /// `working directory` is a property, and `focus` brings the window
    /// forward on its own (checked against Ghostty.sdef). Returns "focused"
    /// or "not found" so TerminalJump can tell a real miss from success.
    public static func ghostty(cwd: String) -> String {
        """
        tell application "Ghostty"
            set matches to every terminal whose working directory contains \(quoted(cwd))
            if (count of matches) > 0 then
                focus item 1 of matches
                return "focused"
            else
                return "not found"
            end if
        end tell
        """
    }

    /// Terminal.app has no "focus a tab" command: select the tab, then
    /// bring its window to front by index (checked against Terminal.sdef).
    /// `activate` only fires on an actual match, so a miss doesn't steal
    /// focus. Returns "focused" or "not found".
    public static func terminalApp(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(quoted(tty)) then
                        activate
                        set selected of t to true
                        set index of w to 1
                        return "focused"
                    end if
                end repeat
            end repeat
            return "not found"
        end tell
        """
    }
}
