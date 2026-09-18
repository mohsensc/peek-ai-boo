import Foundation

/// Parsed form of Resources/ghost.json: two 5-color palettes and, per pose,
/// two 16x16 indexed frames plus that pose's animation rate.
public struct GhostSheet: Sendable, Equatable {
    public static let size = 13

    public struct RGBA: Sendable, Equatable {
        public let r, g, b, a: UInt8
    }

    /// Names the bad palette, pose, frame, row or index so a broken sheet
    /// fails loudly instead of drawing garbage.
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    public let palettes: [String: [RGBA]]
    public let frames: [GhostPose: [[UInt8?]]]
    public let fps: [GhostPose: Double]

    public static func parse(_ data: Data) throws -> GhostSheet {
        guard let json = JSONValue.parse(data) else {
            throw ParseError(message: "ghost.json isn't valid JSON")
        }

        var palettes: [String: [RGBA]] = [:]
        for name in ["warm", "cool"] {
            guard let colors = json["palettes"]?[name]?.arrayValue else {
                throw ParseError(message: "palette \(name) is missing")
            }
            palettes[name] = try colors.map { try rgba(from: $0, palette: name) }
        }
        // Digits index into whichever palette is picked at draw time, so
        // both palettes have to cover the same range.
        let paletteCount = palettes.values.map(\.count).min() ?? 0

        var frames: [GhostPose: [[UInt8?]]] = [:]
        var fps: [GhostPose: Double] = [:]
        for pose in GhostPose.allCases {
            guard let poseFrames = json["frames"]?[pose.rawValue]?.arrayValue else {
                throw ParseError(message: "pose \(pose.rawValue) is missing")
            }
            guard poseFrames.count == 2 else {
                throw ParseError(
                    message: "pose \(pose.rawValue) needs 2 frames, has \(poseFrames.count)")
            }
            frames[pose] = try poseFrames.enumerated().map { frameIndex, frame in
                try parseFrame(frame, pose: pose, frameIndex: frameIndex, paletteCount: paletteCount)
            }

            guard case .number(let rate)? = json["fps"]?[pose.rawValue] else {
                throw ParseError(message: "fps missing for pose \(pose.rawValue)")
            }
            fps[pose] = rate
        }

        return GhostSheet(palettes: palettes, frames: frames, fps: fps)
    }

    private static func parseFrame(
        _ frame: JSONValue, pose: GhostPose, frameIndex: Int, paletteCount: Int
    ) throws -> [UInt8?] {
        guard let rows = frame.arrayValue, rows.count == size else {
            throw ParseError(
                message: "\(pose.rawValue) frame \(frameIndex) needs \(size) rows")
        }
        var cells: [UInt8?] = []
        cells.reserveCapacity(size * size)
        for (rowIndex, rowValue) in rows.enumerated() {
            guard let row = rowValue.stringValue, row.count == size else {
                throw ParseError(
                    message: "\(pose.rawValue) frame \(frameIndex) row \(rowIndex) isn't \(size) wide")
            }
            for ch in row {
                if ch == "." {
                    cells.append(nil)
                } else if let digit = ch.wholeNumberValue, digit >= 0, digit < paletteCount {
                    cells.append(UInt8(digit))
                } else {
                    throw ParseError(
                        message: "\(pose.rawValue) frame \(frameIndex) row \(rowIndex) has an out-of-range index '\(ch)'")
                }
            }
        }
        return cells
    }

    private static func rgba(from value: JSONValue, palette: String) throws -> RGBA {
        guard let hex = value.stringValue, hex.hasPrefix("#"), hex.count == 7,
            let raw = UInt32(hex.dropFirst(), radix: 16)
        else {
            throw ParseError(message: "palette \(palette) has a bad color")
        }
        return RGBA(
            r: UInt8((raw >> 16) & 0xFF),
            g: UInt8((raw >> 8) & 0xFF),
            b: UInt8(raw & 0xFF),
            a: 255)
    }

    /// Claude draws from the warm palette, Codex from the cool one.
    public static func palette(for client: Client) -> String {
        switch client {
        case .claude: return "warm"
        case .codex: return "cool"
        }
    }
}
