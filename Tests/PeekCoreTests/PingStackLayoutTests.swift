import Foundation
import Testing
@testable import PeekCore

@Suite struct PingStackLayoutTests {
    // MARK: ordering and overflow

    @Test func oldestFirstRegardlessOfInputOrder() {
        let items = [
            PingStackLayout.Item(id: "c", ts: 300),
            PingStackLayout.Item(id: "a", ts: 100),
            PingStackLayout.Item(id: "b", ts: 200),
        ]
        let result = PingStackLayout.layout(items)
        #expect(result.rows.map(\.id) == ["a", "b", "c"])
    }

    @Test func upToThreeShownRestOverflow() {
        let items = (0..<5).map { PingStackLayout.Item(id: "\($0)", ts: Int64($0)) }
        let result = PingStackLayout.layout(items)
        // The 3 oldest (longest blocked), then one "+N more" row.
        #expect(result.rows.map(\.id) == ["0", "1", "2", PingStackLayout.overflowID])
        #expect(result.overflow == 2)
    }

    @Test func noOverflowRowAtExactlyTheLimit() {
        let items = (0..<3).map { PingStackLayout.Item(id: "\($0)", ts: Int64($0)) }
        let result = PingStackLayout.layout(items)
        #expect(result.rows.map(\.id) == ["0", "1", "2"])
        #expect(result.overflow == 0)
    }

    @Test func tiesKeepInputOrder() {
        // Same ts: sorted() is stable, so arrival order breaks the tie.
        let items = [
            PingStackLayout.Item(id: "first", ts: 100),
            PingStackLayout.Item(id: "second", ts: 100),
        ]
        #expect(PingStackLayout.layout(items).rows.map(\.id) == ["first", "second"])
    }

    // MARK: row geometry / total height

    @Test func heightMathForZeroThroughFourItems() {
        let h = PingStackLayout.collapsedHeight
        let g = PingStackLayout.gap
        #expect(PingStackLayout.layout([]).totalHeight == 0)

        let one = [PingStackLayout.Item(id: "a", ts: 1)]
        #expect(PingStackLayout.layout(one).totalHeight == h)

        let two = one + [PingStackLayout.Item(id: "b", ts: 2)]
        #expect(PingStackLayout.layout(two).totalHeight == h * 2 + g)

        let three = two + [PingStackLayout.Item(id: "c", ts: 3)]
        #expect(PingStackLayout.layout(three).totalHeight == h * 3 + g * 2)

        // A 4th tips into overflow: 3 rows plus the "+N more" row, which is
        // collapsedHeight tall too.
        let four = three + [PingStackLayout.Item(id: "d", ts: 4)]
        #expect(PingStackLayout.layout(four).totalHeight == h * 4 + g * 3)
    }

    @Test func rowsStackTopDownWithNoOverlap() {
        let items = (0..<3).map { PingStackLayout.Item(id: "\($0)", ts: Int64($0)) }
        let result = PingStackLayout.layout(items)
        for (row, next) in zip(result.rows, result.rows.dropFirst()) {
            #expect(next.y == row.y + row.height + PingStackLayout.gap)
        }
    }

    @Test func customHeightOverridesOneRowWithoutMovingItsPosition() {
        // The card for whichever ping is expanded is much taller than a
        // plain capsule; only that row's height should change.
        let items = (0..<2).map { PingStackLayout.Item(id: "\($0)", ts: Int64($0)) }
        let result = PingStackLayout.layout(items, heights: ["1": 300])
        #expect(result.rows[0].height == PingStackLayout.collapsedHeight)
        #expect(result.rows[1].height == 300)
        #expect(result.rows[1].y == result.rows[0].y + result.rows[0].height + PingStackLayout.gap)
        #expect(result.totalHeight == PingStackLayout.collapsedHeight + PingStackLayout.gap + 300)
    }
}

@Suite struct PingCardHeightTests {
    @Test func hugsShortContentInsteadOfFillingTheCap() {
        let layout = PingCardHeight.layout(header: 40, footer: 80, contentHeight: 100, screenHeight: 982)
        #expect(layout.total == 220)
        #expect(layout.scrollHeight == 100)
    }

    @Test func capsAtAFractionOfScreenHeight() {
        let screenHeight: CGFloat = 982
        let layout = PingCardHeight.layout(header: 40, footer: 80, contentHeight: 2000, screenHeight: screenHeight)
        let expectedCap = screenHeight * PingCardHeight.maxScreenFraction
        #expect(layout.total == expectedCap)
        #expect(layout.scrollHeight == expectedCap - 120)
    }

    @Test func footerNeverLosesRoomEvenOnATinyScreen() {
        // If the 60% cap would be smaller than header+footer, chrome wins:
        // the context area goes to zero rather than clipping the footer.
        let layout = PingCardHeight.layout(header: 40, footer: 80, contentHeight: 500, screenHeight: 10)
        #expect(layout.total == 120)
        #expect(layout.scrollHeight == 0)
    }

    @Test func zeroContentIsJustTheChrome() {
        let layout = PingCardHeight.layout(header: 40, footer: 80, contentHeight: 0, screenHeight: 982)
        #expect(layout.total == 120)
        #expect(layout.scrollHeight == 0)
    }
}

@Suite struct QuestionFitsInlineTests {
    private func opts(_ labels: [String]) -> [Question.Option] {
        labels.map { Question.Option(label: $0, description: "") }
    }

    @Test func fewShortOptionsFitInline() {
        let q = Question(question: "Which guard?", header: "Guard",
                          options: opts(["Closed", "Half", "Butterfly"]), multiSelect: false)
        #expect(q.fitsInline)
    }

    @Test func tooManyOptionsDoNotFit() {
        let q = Question(question: "Pick one", header: "H",
                          options: opts(["A", "B", "C", "D", "E"]), multiSelect: false)
        #expect(!q.fitsInline)
    }

    @Test func longLabelsDoNotFitEvenIfFewOptions() {
        let q = Question(question: "Pick one", header: "H",
                          options: opts(["A much longer option label than usual", "Another long one"]),
                          multiSelect: false)
        #expect(!q.fitsInline)
    }

    @Test func exactlyAtTheCharBudgetFits() {
        // "Closed" + ", " + "Half" + ", " + "Half" = 6+2+4+2+4 = 18 <= 28.
        let q = Question(question: "q", header: "h", options: opts(["Closed", "Half", "Half"]), multiSelect: false)
        #expect(q.fitsInline)
    }

    @Test func noOptionsNeverFits() {
        let q = Question(question: "q", header: "h", options: [], multiSelect: false)
        #expect(!q.fitsInline)
    }
}
