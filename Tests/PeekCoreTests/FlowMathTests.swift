import CoreGraphics
import Testing
@testable import PeekCore

/// The expanded card's answer flow: pack pills left to right, wrap only
/// when one doesn't fit. Widths are the inputs so this stays pure and
/// testable without measuring any real text.
@Suite struct FlowMathWrappingTests {
    @Test func allItemsFitOnOneRow() {
        let result = FlowMath.layout(widths: [50, 50, 50], itemHeight: 30, maxWidth: 200, spacing: 6, lineSpacing: 6)
        #expect(result.rowCount == 1)
        #expect(result.positions.map(\.row) == [0, 0, 0])
        #expect(result.positions.map(\.x) == [0, 56, 112])
        #expect(result.height == 30)
    }

    @Test func wrapsOnlyWhenTheNextItemDoesNotFit() {
        // 50 + 6 + 50 = 106 fits in 120; a third 50 would need 106+6+50=162.
        let result = FlowMath.layout(widths: [50, 50, 50], itemHeight: 30, maxWidth: 120, spacing: 6, lineSpacing: 6)
        #expect(result.positions.map(\.row) == [0, 0, 1])
        #expect(result.positions[0].x == 0)
        #expect(result.positions[1].x == 56)
        #expect(result.positions[2].x == 0)
        #expect(result.rowCount == 2)
        // Two rows plus one gap between them: 30*2 + 6, spelled as a
        // CGFloat literal -- bare mixed-literal arithmetic here (`30 * 2 +
        // 6`) type-checks fine but #expect's macro capture compares it as
        // an untyped Int against result.height's CGFloat and always reports
        // a false mismatch, despite printing the same value on both sides.
        #expect(result.height == CGFloat(66))
    }

    @Test func everyItemOnItsOwnRowWhenNoneFitTogether() {
        let result = FlowMath.layout(widths: [100, 100, 100], itemHeight: 30, maxWidth: 100, spacing: 6, lineSpacing: 6)
        #expect(result.positions.map(\.row) == [0, 1, 2])
        #expect(result.positions.allSatisfy { $0.x == 0 })
        #expect(result.rowCount == 3)
        #expect(result.height == CGFloat(102))
    }

    @Test func oneItemWiderThanMaxWidthStillPlacesAlone() {
        // Nothing to wrap against -- it just draws past maxWidth, same as a
        // single word too long for its column.
        let result = FlowMath.layout(widths: [500], itemHeight: 30, maxWidth: 100, spacing: 6, lineSpacing: 6)
        #expect(result.positions == [FlowMath.Position(x: 0, y: 0, row: 0)])
        #expect(result.height == 30)
    }

    @Test func emptyWidthsIsEmpty() {
        let result = FlowMath.layout(widths: [], itemHeight: 30, maxWidth: 200, spacing: 6, lineSpacing: 6)
        #expect(result.positions.isEmpty)
        #expect(result.height == 0)
        #expect(result.rowCount == 0)
    }

    @Test func exactlyAtTheEdgeFitsRatherThanWrapping() {
        // 50 + 6 + 44 == 100 exactly: should still share the row.
        let result = FlowMath.layout(widths: [50, 44], itemHeight: 30, maxWidth: 100, spacing: 6, lineSpacing: 6)
        #expect(result.positions.map(\.row) == [0, 0])
    }
}

/// The card's multi-select flow appends a Send pill after Other. This
/// checks it lands where the wrap math says it should -- sharing the last
/// row when there's room, its own new row when there isn't -- not that it's
/// hardcoded to either.
@Suite struct FlowMathSendPlacementTests {
    // Four options ("Closed"/"Half"/"Butterfly"/"Mount"-shaped widths),
    // Other, then Send -- the guard question's real shape.
    private let optionWidths: [CGFloat] = [70, 60, 90, 74]
    private let otherWidth: CGFloat = 66
    private let sendWidth: CGFloat = 62

    @Test func sendSharesTheLastRowWhenThereIsRoom() {
        let widths = optionWidths + [otherWidth, sendWidth]
        let result = FlowMath.layout(widths: widths, itemHeight: 30, maxWidth: 600, spacing: 6, lineSpacing: 6)
        let sendRow = result.positions.last!.row
        let otherRow = result.positions[result.positions.count - 2].row
        #expect(sendRow == otherRow)
        #expect(result.rowCount == 1)
    }

    @Test func sendWrapsToItsOwnRowWhenTheLastRowIsFull() {
        // A narrow card: pack until Other, then Send has to be the one that
        // doesn't fit and starts a fresh row.
        let widths = optionWidths + [otherWidth, sendWidth]
        let result = FlowMath.layout(widths: widths, itemHeight: 30, maxWidth: 150, spacing: 6, lineSpacing: 6)
        let sendPosition = result.positions.last!
        #expect(sendPosition.x == 0)
        #expect(sendPosition.row == result.rowCount - 1)
        // And it isn't sharing that fresh row with anything already placed
        // earlier -- it's the only item at that row's start.
        #expect(result.positions.dropLast().allSatisfy { $0.row < sendPosition.row })
    }

    @Test func sendIsAlwaysTheLastPositionRegardlessOfWrapping() {
        for maxWidth: CGFloat in [80, 150, 250, 400, 800] {
            let widths = optionWidths + [otherWidth, sendWidth]
            let result = FlowMath.layout(widths: widths, itemHeight: 30, maxWidth: maxWidth, spacing: 6, lineSpacing: 6)
            #expect(result.positions.count == widths.count)
            // Send never appears before Other -- order is preserved, only
            // wrapping changes.
            let sendRow = result.positions.last!.row
            let otherRow = result.positions[result.positions.count - 2].row
            #expect(sendRow >= otherRow)
        }
    }
}
