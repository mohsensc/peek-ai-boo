import Foundation
import PeekCore

/// Focuses the terminal behind a session on click. Always claims the row
/// (this is the whole point of clicking a session), so a failed jump just
/// leaves a note instead of falling through to another feature.
final class TerminalJump: Feature {
    func open(_ session: Session, app: AppModel) -> Bool {
        let plan = JumpPlan.make(term: session.term, cwd: session.cwd)
        let key = session.id
        DispatchQueue.global(qos: .userInitiated).async {
            let note = TerminalJump.run(plan)
            DispatchQueue.main.async {
                app.setNote(key, note)
            }
        }
        return true
    }

    /// Off the main thread: Process for cmux, NSAppleScript for the rest.
    /// Returns the note to leave on the row, or nil to clear it. `Feature`
    /// is @MainActor, so this needs `nonisolated` to actually run on the
    /// background queue it's dispatched onto.
    private nonisolated static func run(_ plan: JumpPlan) -> String? {
        switch plan {
        case .cmux(let cli, let socket, let commands):
            return runCmux(cli: cli, socket: socket, commands: commands)
        case .ghostty(let script), .terminalApp(let script):
            return runAppleScript(script)
        case .none(let reason):
            return reason
        }
    }

    private nonisolated static func runCmux(cli: String, socket: String?, commands: [[String]]) -> String? {
        var env = ProcessInfo.processInfo.environment
        if let socket { env["CMUX_SOCKET_PATH"] = socket }
        for args in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            process.environment = env
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    return "cmux exited \(process.terminationStatus)"
                }
            } catch {
                return "can't run cmux"
            }
        }
        return nil
    }

    private nonisolated static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return "bad script" }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if let number = errorInfo[NSAppleScript.errorNumber] as? Int, number == -1743 {
                return "Automation not allowed"
            }
            return errorInfo[NSAppleScript.errorMessage] as? String ?? "can't jump to terminal"
        }
        // Both scripts return "focused" or "not found" so a clean run that
        // never matched a terminal doesn't get treated as success.
        return result.stringValue == "not found" ? "terminal not found" : nil
    }
}
