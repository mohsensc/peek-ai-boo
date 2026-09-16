import Foundation
import Testing

@testable import PeekCore

@Suite struct GhostSheetTests {
    static func loadRealSheet() throws -> GhostSheet {
        let url = repoRoot.appendingPathComponent("Resources").appendingPathComponent("ghost.json")
        return try GhostSheet.parse(try Data(contentsOf: url))
    }

    @Test func parsesRealSheet() throws {
        let sheet = try Self.loadRealSheet()
        #expect(sheet.palettes["warm"]?.count == 5)
        #expect(sheet.palettes["cool"]?.count == 5)
        for pose in GhostPose.allCases {
            let frames = try #require(sheet.frames[pose])
            #expect(frames.count == 2)
            for frame in frames {
                #expect(frame.count == GhostSheet.size * GhostSheet.size)
            }
            #expect(sheet.fps[pose] != nil)
        }
        // working blinks slower on purpose.
        #expect(sheet.fps[.working] == 1.5)
    }

    @Test func digitsMapToTheRightPaletteColor() throws {
        let sheet = try Self.loadRealSheet()
        // Row 1 of idle frame 0 is "......0000......": index 6 is digit '0'.
        let idx = 1 * GhostSheet.size + 6
        #expect(sheet.frames[.idle]?[0][idx] == 0)
        let warm0 = try #require(sheet.palettes["warm"]?[0])
        #expect(warm0 == GhostSheet.RGBA(r: 0x5A, g: 0x2A, b: 0x1F, a: 255))
    }

    @Test func dotIsTransparent() throws {
        let sheet = try Self.loadRealSheet()
        // Row 0 of idle frame 0 is all dots.
        let idx = 0 * GhostSheet.size + 0
        #expect(sheet.frames[.idle]?[0][idx] == nil)
    }

    @Test func paletteForClient() {
        #expect(GhostSheet.palette(for: .claude) == "warm")
        #expect(GhostSheet.palette(for: .codex) == "cool")
    }

    // MARK: - malformed sheets

    private static let blankFrame = Array(repeating: String(repeating: ".", count: 16), count: 16)

    private static func sheetJSON(
        frameOverride: [String: Any]? = nil,
        fpsOverride: [String: Any]? = nil,
        dropFPS: String? = nil
    ) -> Data {
        var frames: [String: Any] = [:]
        for pose in GhostPose.allCases {
            frames[pose.rawValue] = [blankFrame, blankFrame]
        }
        if let frameOverride {
            for (k, v) in frameOverride { frames[k] = v }
        }
        var fps: [String: Any] = ["idle": 2, "working": 1.5, "needs": 4, "done": 1]
        if let fpsOverride {
            for (k, v) in fpsOverride { fps[k] = v }
        }
        if let dropFPS {
            fps.removeValue(forKey: dropFPS)
        }
        let hexes = ["#5A2A1F", "#D97757", "#BF5F42", "#2B1712", "#F6C453"]
        let obj: [String: Any] = [
            "size": 16,
            "palettes": ["warm": hexes, "cool": hexes],
            "frames": frames,
            "fps": fps,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func validSyntheticSheetParses() throws {
        _ = try GhostSheet.parse(Self.sheetJSON())
    }

    @Test func narrowRowThrows() {
        var badFrame = Self.blankFrame
        badFrame[0] = String(repeating: ".", count: 15)
        let data = Self.sheetJSON(frameOverride: ["idle": [badFrame, Self.blankFrame]])
        #expect(throws: GhostSheet.ParseError.self) { try GhostSheet.parse(data) }
    }

    @Test func missingPoseThrows() {
        var frames: [String: Any] = [:]
        for pose in GhostPose.allCases where pose != .needs {
            frames[pose.rawValue] = [Self.blankFrame, Self.blankFrame]
        }
        let hexes = ["#5A2A1F", "#D97757", "#BF5F42", "#2B1712", "#F6C453"]
        let obj: [String: Any] = [
            "size": 16,
            "palettes": ["warm": hexes, "cool": hexes],
            "frames": frames,
            "fps": ["idle": 2, "working": 1.5, "needs": 4, "done": 1],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        #expect(throws: GhostSheet.ParseError.self) { try GhostSheet.parse(data) }
    }

    @Test func missingFPSThrows() {
        let data = Self.sheetJSON(dropFPS: "needs")
        #expect(throws: GhostSheet.ParseError.self) { try GhostSheet.parse(data) }
    }

    @Test func outOfRangeDigitThrows() {
        var badFrame = Self.blankFrame
        badFrame[0] = "9" + String(repeating: ".", count: 15)
        let data = Self.sheetJSON(frameOverride: ["idle": [badFrame, Self.blankFrame]])
        #expect(throws: GhostSheet.ParseError.self) { try GhostSheet.parse(data) }
    }
}
