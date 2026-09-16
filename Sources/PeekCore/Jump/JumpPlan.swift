import Foundation

/// Where a click on a session row should go. First match wins: cmux, then
/// Ghostty, then Terminal.app, else none. docs/design.md "Terminal jump".
public enum JumpPlan: Sendable, Equatable {
    /// Run in order with CMUX_SOCKET_PATH=socket in the environment.
    case cmux(cli: String, socket: String?, commands: [[String]])
    case ghostty(script: String)
    case terminalApp(script: String)
    case none(reason: String)

    public static func make(term: Term, cwd: String?) -> JumpPlan {
        // cmux first: it sets TERM_PROGRAM=ghostty too, so this has to beat
        // the ghostty check below.
        if let surface = nonEmpty(term.cmuxSurface) {
            guard let cli = nonEmpty(term.cmuxCli) else {
                return .none(reason: "cmux cli missing")
            }
            var commands: [[String]] = []
            if let workspace = nonEmpty(term.cmuxWorkspace) {
                commands.append(["select-workspace", "--workspace", workspace])
            }
            commands.append(["focus-panel", "--panel", surface])
            return .cmux(cli: cli, socket: nonEmpty(term.cmuxSocket), commands: commands)
        }

        if term.program == "ghostty" {
            guard let cwd = nonEmpty(cwd) else { return .none(reason: "no terminal info") }
            return .ghostty(script: AppleScriptText.ghostty(cwd: cwd))
        }

        if term.program == "Apple_Terminal" {
            guard let tty = nonEmpty(term.tty) else { return .none(reason: "no terminal info") }
            return .terminalApp(script: AppleScriptText.terminalApp(tty: tty))
        }

        if let program = nonEmpty(term.program) {
            return .none(reason: "can't jump to \(program)")
        }
        return .none(reason: "no terminal info")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
