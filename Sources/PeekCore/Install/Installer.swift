import Foundation

public enum InstallerError: Error, CustomStringConvertible {
    /// The command's first word has to end in "/peekaboo-hook" to be
    /// recognized as ours later, and a space in the path would break that.
    case hookPathHasSpace(String)
    case malformedJSON(String)
    /// "hooks" is present but isn't the matcher-groups-by-event shape we
    /// know how to merge into. Refuse rather than silently replace it.
    case unexpectedHooksShape(String)

    public var description: String {
        switch self {
        case .hookPathHasSpace(let path):
            return "hook path has a space, can't be matched as ours: \(path)"
        case .malformedJSON(let path):
            return "\(path) isn't valid JSON, left untouched"
        case .unexpectedHooksShape(let path):
            return "\(path)'s \"hooks\" key isn't in the shape we expect, left untouched"
        }
    }
}

/// Copies the hook binary into place and merges each client's hook config.
/// Every file write goes through the same backup-then-atomic-replace path,
/// for install and for uninstall alike.
public struct Installer {
    private let home: String
    private let paths: Paths
    private let hookSource: String
    private let specs: [HookSpec]
    private let now: () -> Date

    public init(home: String, paths: Paths, hookSource: String, specs: [HookSpec], now: @escaping () -> Date = Date.init) {
        self.home = home
        self.paths = paths
        self.hookSource = hookSource
        self.specs = specs
        self.now = now
    }

    /// Copies the hook to paths.hookBinary (0755), then merges each spec's
    /// file. Returns the lines to print (afterChange notes included).
    public func install() throws -> [String] {
        try validateHookPath()
        try installHookBinary()
        var lines: [String] = []
        for spec in specs {
            guard let line = try merge(spec: spec, isInstall: true) else { continue }
            lines.append(line)
            if let after = spec.afterChange { lines.append(after) }
        }
        return lines
    }

    public func uninstall() throws -> [String] {
        try validateHookPath()
        var lines: [String] = []
        for spec in specs {
            guard let line = try merge(spec: spec, isInstall: false) else { continue }
            lines.append(line)
            if let after = spec.afterChange { lines.append(after) }
        }
        return lines
    }

    private func validateHookPath() throws {
        guard !paths.hookBinary.contains(" ") else {
            throw InstallerError.hookPathHasSpace(paths.hookBinary)
        }
    }

    private func installHookBinary() throws {
        let destPath = paths.hookBinary
        let destURL = URL(fileURLWithPath: destPath)
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
        }
        try FileManager.default.copyItem(atPath: hookSource, toPath: destPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
    }

    /// Backs up an existing file (original bytes, original mode), merges
    /// `spec` into it with `addOurs` (install) or `removeOurs` (uninstall),
    /// and writes the result atomically in the original mode. A missing
    /// file is only created on install, and only if its parent dir exists
    /// (no `~/.codex` means Codex isn't installed). Returns the line to
    /// report, or nil if there was nothing to do.
    private func merge(spec: HookSpec, isInstall: Bool) throws -> String? {
        let path = home + "/" + spec.configPath
        let parentDir = (path as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let fileExisted = FileManager.default.fileExists(atPath: path)
        guard fileExisted || isInstall else { return nil }

        var root: [String: Any] = [:]
        var mode: Int = 0o644
        var original: Data?
        if fileExisted {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber {
                mode = perms.intValue
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let asDict = parsed as? [String: Any] else {
                throw InstallerError.malformedJSON(path)
            }
            if let hooksValue = asDict["hooks"], !(hooksValue is [String: Any]) {
                throw InstallerError.unexpectedHooksShape(path)
            }
            root = asDict
            original = data
        }

        let updated = isInstall
            ? HookConfig.addOurs(to: root, spec: spec, hookPath: paths.hookBinary)
            : HookConfig.removeOurs(from: root)

        // Nothing would change: uninstalling a file we never touched, say.
        // Don't back it up or reformat it for no reason.
        if fileExisted, (updated as NSDictionary).isEqual(to: root) {
            return nil
        }

        if fileExisted, let original {
            let backupPath = path + ".peek-ai-boo.\(Int(now().timeIntervalSince1970)).bak"
            try original.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: backupPath)
        }

        let data = try HookConfig.encode(updated)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)

        let display = "~" + path.dropFirst(home.count)
        return "wrote \(display)"
    }
}
