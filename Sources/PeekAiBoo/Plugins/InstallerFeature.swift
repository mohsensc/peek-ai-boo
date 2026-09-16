import AppKit
import Foundation
import PeekCore

/// `--install-hooks` / `--uninstall-hooks` on the command line, and the
/// same two actions from the island's right-click menu.
@MainActor
final class InstallerFeature: NSObject, Feature {
    func run(arguments: [String]) -> Int32? {
        if arguments.contains("--install-hooks") {
            return runFromCommandLine(install: true)
        }
        if arguments.contains("--uninstall-hooks") {
            return runFromCommandLine(install: false)
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

    private func runFromCommandLine(install: Bool) -> Int32 {
        do {
            let lines = try install ? makeInstaller().install() : makeInstaller().uninstall()
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
            let lines = try install ? makeInstaller().install() : makeInstaller().uninstall()
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
}
