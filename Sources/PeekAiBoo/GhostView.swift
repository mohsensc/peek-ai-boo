import CoreGraphics
import PeekCore
import SwiftUI

/// Pixel ghost sprites decoded from Resources/ghost.json. The sheet and its
/// rendered frames load once and never again; body just picks a frame.
struct GhostView: View {
    let client: Client
    let pose: GhostPose
    let phase: Double?

    var body: some View {
        let key = Store.Key(palette: GhostSheet.palette(for: client), pose: pose, frame: frameIndex)
        let size = CGFloat(GhostSheet.size)
        if let image = Store.shared.images[key] {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    /// nil phase (not moving) always shows frame 0. Otherwise the pose's own
    /// fps picks between its 2 baked-in frames, which is also where the idle
    /// bob and the working/needs/done detail live, so there's nothing else
    /// to animate here.
    private var frameIndex: Int {
        guard let phase else { return 0 }
        let fps = Store.shared.sheet.fps[pose] ?? 1
        return Int(phase * fps) % 2
    }

    /// Loads ghost.json and pre-renders every palette/pose/frame combination
    /// once, so drawing never allocates.
    private final class Store: @unchecked Sendable {
        struct Key: Hashable {
            let palette: String
            let pose: GhostPose
            let frame: Int
        }

        static let shared = Store()

        let sheet: GhostSheet
        let images: [Key: CGImage]

        private init() {
            guard let url = Bundle.main.url(forResource: "ghost", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let sheet = try? GhostSheet.parse(data)
            else {
                fatalError("ghost.json missing, build with scripts/build-app.sh")
            }
            self.sheet = sheet

            var images: [Key: CGImage] = [:]
            for (palette, colors) in sheet.palettes {
                for pose in GhostPose.allCases {
                    for (frame, cells) in (sheet.frames[pose] ?? []).enumerated() {
                        if let image = Store.render(cells: cells, colors: colors) {
                            images[Key(palette: palette, pose: pose, frame: frame)] = image
                        }
                    }
                }
            }
            self.images = images
        }

        private static func render(cells: [UInt8?], colors: [GhostSheet.RGBA]) -> CGImage? {
            let size = GhostSheet.size
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for (i, cell) in cells.enumerated() {
                guard let cell, Int(cell) < colors.count else { continue }
                let color = colors[Int(cell)]
                let o = i * 4
                pixels[o] = color.r
                pixels[o + 1] = color.g
                pixels[o + 2] = color.b
                pixels[o + 3] = color.a
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: size, height: size,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}
