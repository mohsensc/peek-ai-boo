import Foundation

/// Our own JSON tree instead of `Any` from JSONSerialization, so bools and
/// numbers don't collide (JSONSerialization hands both back as NSNumber).
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) else { return nil }
        return JSONValue(any: any)
    }

    private init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // CFBoolean is the only NSNumber that's actually a bool. Plain
            // numbers come back as NSNumber too, and CFGetTypeID tells them
            // apart (objCType alone lies for some bridged numbers).
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.compactMap { JSONValue(any: $0) })
        case let o as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (k, v) in o {
                guard let jv = JSONValue(any: v) else { return nil }
                result[k] = jv
            }
            self = .object(result)
        default:
            return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let a) = self else { return nil }
        return a
    }

    public var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    public var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        return Int(n)
    }
}
