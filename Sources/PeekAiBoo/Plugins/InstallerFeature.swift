import AppKit
import Foundation
import PeekCore

/// `--install-hooks` / `--uninstall-hooks` on the command line, and the
/// same two actions from the island's right-click menu.
@MainActor
final class InstallerFeature: NSObject, Feature {
    func run(arguments: [String]) -> Int32? {
        if arguments.contains("--install-hooks") {
            return runFromCommandLine(install: true, skipLoginItem: arguments.contains("--no-login-item"))
        }
        if arguments.contains("--uninstall-hooks") {
            return runFromCommandLine(install: false, skipLoginItem: false)
        }
        return nil
    }

    func menuItems(app: AppModel) -> [NSMenuItem] {
        let install = NSMenuItem(title: "Install hooks", action: #selector(installTapped), keyEquivalent: "")
        install.target = self
        let uninstall = NSMenuItem(title: "Uninstall hooks", action: #selector(uninstallTapped), keyEquivalent: "")
        uninstall.target = self
        return [install, uninstall]
    }

    private func runFromCommandLine(install: Bool, skipLoginItem: Bool) -> Int32 {
        do {
            var lines = try install ? makeInstaller().install() : makeInstaller().uninstall()
            lines += try runLoginItem(install: install, skipLoginItem: skipLoginItem)
            for line in lines { print(line) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    @objc private func installTapped() { runFromMenu(install: true) }
    @objc private func uninstallTapped() { runFromMenu(install: false) }

    private func runFromMenu(install: Bool) {
        let alert = NSAlert()
        do {
            var lines = try install ? makeInstaller().install() : makeInstaller().uninstall()
            lines += try runLoginItem(install: install, skipLoginItem: false)
            alert.messageText = install ? "Hooks installed" : "Hooks uninstalled"
            alert.informativeText = lines.isEmpty ? "Nothing to do." : lines.joined(separator: "\n")
        } catch {
            alert.messageText = install ? "Install failed" : "Uninstall failed"
            alert.informativeText = "\(error)"
        }
        alert.runModal()
    }

    private func makeInstaller() -> Installer {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let hookSource = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/peekaboo-hook").path
        return Installer(
            home: home, paths: Paths.fromEnvironment(), hookSource: hookSource,
            specs: Clients.hookSpecs())
    }

    /// Writes or removes the LaunchAgent plist. Loading it live is
    /// install.sh's job (see LoginItem's doc comment) -- on install this
    /// only ever touches the file. On uninstall, and on a reinstall with
    /// --no-login-item, it also tries to unload the running job now, not
    /// just at next login, so a stale KeepAlive registration can't outlive
    /// the plist that describes it.
    private func runLoginItem(install: Bool, skipLoginItem: Bool) throws -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        if install && skipLoginItem {
            // --no-login-item means "there is no login item", not just
            // "don't add one" -- a reinstall over a previous plain install
            // has to take back what that one left behind.
            guard let line = try LoginItem.uninstall(home: home) else { return [] }
            unloadLoginItemIfLive()
            return [line]
        }
        if install {
            let programPath = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/PeekAiBoo").path
            return [try LoginItem.install(home: home, programPath: programPath)]
        }
        guard let line = try LoginItem.uninstall(home: home) else { return [] }
        unloadLoginItemIfLive()
        return [line]
    }

    /// `launchctl bootout`s the job so launchd stops supervising it this
    /// session too, not just at the next login. Skipped when
    /// PEEKABOO_SKIP_LAUNCHCTL is set -- scripts/checks/installer.sh sets
    /// it, since gui/$UID is the real login session regardless of the fake
    /// $HOME the rest of that check runs against, and a test process has
    /// no business unloading whatever's really registered there.
    private func unloadLoginItemIfLive() {
        guard ProcessInfo.processInfo.environment["PEEKABOO_SKIP_LAUNCHCTL"] == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(LoginItem.label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
