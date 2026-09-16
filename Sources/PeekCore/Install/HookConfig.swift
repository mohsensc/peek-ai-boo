import Foundation

/// Reads and rewrites a client's hook config (settings.json-shaped: a
/// top-level "hooks" object keyed by event name, each value an array of
/// matcher groups). Everything else in the file passes through untouched.
public enum HookConfig {
    /// First word of a command ends in "/peekaboo-hook". A bare basename
    /// with no slash (someone's own script called peekaboo-hook-old) isn't
    /// ours, and neither is a wrapper that only mentions us later in the line.
    public static func isOurs(_ command: String) -> Bool {
        guard let firstWord = command.split(whereSeparator: { $0.isWhitespace }).first else {
            return false
        }
        return firstWord.hasSuffix("/peekaboo-hook")
    }

    /// Drops our hook objects, then any group or event key that's left with
    /// nothing in it. Foreign entries in the same group or event survive
    /// untouched, in place.
    public static func removeOurs(from root: [String: Any]) -> [String: Any] {
        var result = root
        guard let hooks = root["hooks"] as? [String: Any] else { return result }

        var newHooks: [String: Any] = [:]
        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                // Not the shape we know how to filter: leave it as we found it.
                newHooks[eventName] = value
                continue
            }
            var newGroups: [[String: Any]] = []
            for group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else {
                    newGroups.append(group)
                    continue
                }
                let filtered = entries.filter { entry in
                    guard let command = entry["command"] as? String else { return true }
                    return !isOurs(command)
                }
                if filtered.isEmpty { continue }  // the group was only ever ours
                if filtered.count == entries.count {
                    newGroups.append(group)  // unchanged, keep the original object
                } else {
                    var trimmed = group
                    trimmed["hooks"] = filtered
                    newGroups.append(trimmed)
                }
            }
            if !newGroups.isEmpty {
                newHooks[eventName] = newGroups
            }
        }

        if newHooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = newHooks
        }
        return result
    }

    /// removeOurs, then one new group per event with our command. Calling
    /// this twice in a row produces the same bytes as calling it once: it
    /// always starts by clearing out whatever we left behind last time.
    public static func addOurs(to root: [String: Any], spec: HookSpec, hookPath: String) -> [String: Any] {
        var result = removeOurs(from: root)
        var hooks = (result["hooks"] as? [String: Any]) ?? [:]
        let command = "\(hookPath) --client \(spec.client.rawValue)"

        for event in spec.events {
            var group: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "timeout": event.timeout,
                    ] as [String: Any]
                ]
            ]
            if let matcher = event.matcher {
                group["matcher"] = matcher
            }
            var existing = (hooks[event.name] as? [[String: Any]]) ?? []
            existing.append(group)
            hooks[event.name] = existing
        }

        result["hooks"] = hooks
        return result
    }

    /// Pretty, sorted keys, no escaped slashes, trailing newline. Key order
    /// isn't preserved from the original file either way, since
    /// JSONSerialization already drops it on the read.
    public static func encode(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }
}
