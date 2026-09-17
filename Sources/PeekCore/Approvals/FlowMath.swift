import CoreGraphics

/// Pure wrapping math for a left-to-right flow of fixed-width items (the
/// expanded question card's option pills, Other, and multiSelect's Send
/// capsule): pack as many as fit on a line, wrap to the next only when one
/// doesn't. Shared by the SwiftUI `Layout` that actually draws the flow and
/// by the card's height estimate, so the window AppKit sizes and the pixels
/// SwiftUI draws never disagree — same reasoning as PingStackLayout for the
/// row stack itself.
public enum FlowMath {
    public struct Position: Equatable {
        public let x: CGFloat
        public let y: CGFloat
        public let row: Int
        public init(x: CGFloat, y: CGFloat, row: Int) {
            self.x = x
            self.y = y
            self.row = row
        }
    }

    public struct Result: Equatable {
        public let positions: [Position]
        public let height: CGFloat
        public let rowCount: Int
    }

    /// One position per entry in `widths`, in order, plus the total height
    /// the flow needs at that `maxWidth`. Every item shares `itemHeight` —
    /// every pill in this app draws at the same height — so a row's height
    /// is just that constant, not a per-item measurement.
    public static func layout(
        widths: [CGFloat], itemHeight: CGFloat, maxWidth: CGFloat,
        spacing: CGFloat, lineSpacing: CGFloat
    ) -> Result {
        guard !widths.isEmpty else { return Result(positions: [], height: 0, rowCount: 0) }
        var positions: [Position] = []
        var x: CGFloat = 0
        var row = 0
        for (i, width) in widths.enumerated() {
            if i > 0 {
                if x + spacing + width > maxWidth {
                    x = 0
                    row += 1
                } else {
                    x += spacing
                }
            }
            positions.append(Position(x: x, y: CGFloat(row) * (itemHeight + lineSpacing), row: row))
            x += width
        }
        let height = CGFloat(row + 1) * itemHeight + CGFloat(row) * lineSpacing
        return Result(positions: positions, height: height, rowCount: row + 1)
    }
}
