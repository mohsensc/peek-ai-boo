import Foundation

/// The `~/Library/LaunchAgents` plist that starts PeekAiBoo at login.
/// Writing and removing the file is all this does -- same split as hooks,
/// which need a Claude Code restart to take effect and aren't reloaded
/// here either. Making it live in the current session (`launchctl
/// bootstrap`/`bootout`) is install.sh's job for install, since that's the
/// one path with real fallback logic worth keeping in shell; uninstall
/// shells out itself, from InstallerFeature, since there's no
/// uninstall.sh to put it in.
public enum LoginItem {
    /// Same string as the app's CFBundleIdentifier (see build-app.sh), so
    /// the label always names exactly one app.
    public static let label = "com.mohsensc.peekaiboo"

    public static func plistPath(home: String) -> String {
        home + "/Library/LaunchAgents/\(label).plist"
    }

    /// RunAtLoad starts it now (once install.sh bootstraps the job) and at
    /// every login after. KeepAlive only restarts on a *non-zero* exit --
    /// a crash -- so a deliberate Quit (NSApp.terminate, exit 0) and the
    /// single-instance check (LineServer.isListening finds another copy
    /// up, also exit 0) both stay quit instead of launchd bouncing them
    /// back.
    static func plistContents(programPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(programPath)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        </dict>
        </plist>
        """
    }

    /// Writes the plist (0644, parent dir made if needed, overwritten if
    /// present) so twice equals once. Returns the line to print.
    @discardableResult
    public static func install(home: String, programPath: String) throws -> String {
        let path = plistPath(home: home)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(plistContents(programPath: programPath).utf8)
            .write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        let display = "~" + path.dropFirst(home.count)
        return "wrote \(display)"
    }

    /// Removes the plist if present. Returns nil (nothing to report) if
    /// there was nothing there.
    @discardableResult
    public static func uninstall(home: String) throws -> String? {
        let path = plistPath(home: home)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        try FileManager.default.removeItem(atPath: path)
        let display = "~" + path.dropFirst(home.count)
        return "removed \(display)"
    }
}
