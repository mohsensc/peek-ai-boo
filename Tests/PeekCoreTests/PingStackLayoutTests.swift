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

        // A 4th tips into overflow: 3 rows plus the "+N more" row, which
        // stays a single line (overflowHeight) rather than paying for the
        // two-line row height the real capsules need.
        let four = three + [PingStackLayout.Item(id: "d", ts: 4)]
        #expect(PingStackLayout.layout(four).totalHeight == h * 3 + g * 3 + PingStackLayout.overflowHeight)
    }

    @Test func overflowRowUsesItsOwnHeightNotTheCollapsedOne() {
        let items = (0..<4).map { PingStackLayout.Item(id: "\($0)", ts: Int64($0)) }
        let result = PingStackLayout.layout(items)
        #expect(result.rows.last?.id == PingStackLayout.overflowID)
        #expect(result.rows.last?.height == PingStackLayout.overflowHeight)
        #expect(PingStackLayout.overflowHeight != PingStackLayout.collapsedHeight)
    }

    @Test func collapsedRowIsTwoLinesAndNoLongerACapsule() {
        #expect(PingStackLayout.collapsedHeight ==
            PingStackLayout.rowOnePadding + PingStackLayout.rowOneHeight
            + PingStackLayout.rowSpacing + PingStackLayout.rowTwoHeight + PingStackLayout.rowTwoPadding)
        // A true capsule's corner radius is half its height; this one has to
        // be smaller, or the "rounded rect with concentric corners" the
        // design calls for draws as a capsule again.
        #expect(PingStackLayout.collapsedCornerRadius < PingStackLayout.collapsedHeight / 2)
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

/// The layout decision itself: two short single-select options draw inline
/// in row 1 (replacing deny/allow); everything else — 3+ options,
/// multiSelect, or labels too wide — falls to the "asks · N" count-and-
/// expand row instead.
@Suite struct QuestionFitsInlineTests {
    private func opts(_ labels: [String]) -> [Question.Option] {
        labels.map { Question.Option(label: $0, description: "") }
    }

    @Test func twoShortOptionsFitInline() {
        let q = Question(question: "Dark or light?", header: "Theme",
                          options: opts(["Dark", "Light"]), multiSelect: false)
        #expect(q.fitsInline)
    }

    @Test func threeOptionsDoNotFitEvenIfShort() {
        let q = Question(question: "Which guard?", header: "Guard",
                          options: opts(["Closed", "Half", "Mount"]), multiSelect: false)
        #expect(!q.fitsInline)
        #expect(Question.expandCount([q]) == 3)
    }

    @Test func multiSelectTwoShortOptionsDoNotFit() {
        // Count and length alone aren't enough — row 1 only ever answers a
        // single pick directly, never a toggle set.
        let q = Question(question: "Which toppings?", header: "Toppings",
                          options: opts(["Cheese", "Basil"]), multiSelect: true)
        #expect(!q.fitsInline)
    }

    @Test func twoLongOptionsDoNotFitEvenAtTheRightCount() {
        let q = Question(question: "Pick one", header: "H",
                          options: opts(["A much longer option", "Another long one"]),
                          multiSelect: false)
        #expect(!q.fitsInline)
    }

    @Test func exactlyAtTheCharBudgetFits() {
        // "Approve" + "Reject" = 7 + 6 = 13 <= 16.
        let q = Question(question: "q", header: "h", options: opts(["Approve", "Reject"]), multiSelect: false)
        #expect(q.fitsInline)
    }

    @Test func oneCharOverBudgetDoesNotFit() {
        // 8 + 9 = 17 > 16, one past exactlyAtTheCharBudgetFits's 13.
        let q = Question(question: "q", header: "h", options: opts(["AAAAAAAA", "BBBBBBBBB"]), multiSelect: false)
        #expect(!q.fitsInline)
    }

    @Test func oneOptionDoesNotFit() {
        let q = Question(question: "q", header: "h", options: opts(["Only"]), multiSelect: false)
        #expect(!q.fitsInline)
    }

    @Test func noOptionsNeverFits() {
        let q = Question(question: "q", header: "h", options: [], multiSelect: false)
        #expect(!q.fitsInline)
    }
}

@Suite struct QuestionExpandCountTests {
    private func q(_ n: Int) -> Question {
        Question(question: "q", header: "h",
                  options: (0..<n).map { Question.Option(label: "\($0)", description: "") }, multiSelect: false)
    }

    @Test func singleQuestionCountsItsOwnOptions() {
        #expect(Question.expandCount([q(4)]) == 4)
    }

    @Test func multipleQuestionsSumEveryOption() {
        #expect(Question.expandCount([q(3), q(2)]) == 5)
    }

    @Test func noQuestionsIsZero() {
        #expect(Question.expandCount([]) == 0)
    }
}

@Suite struct DoneRowSelectionTests {
    private func item(_ id: String, _ ts: Int64, done: Bool = false) -> PingStackLayout.Item {
        PingStackLayout.Item(id: id, ts: ts, isDone: done)
    }

    @Test func doneNeverCountsTowardOverflow() {
        // 3 blocking (the visible cap) plus 2 done: overflow only ever
        // measures blocking, so it stays 0 even though 2 rows are hidden.
        let items = (0..<3).map { item("b\($0)", Int64($0)) }
            + (0..<2).map { item("d\($0)", Int64(10 + $0), done: true) }
        let selection = PingStackLayout.selectShown(items)
        #expect(selection.overflow == 0)
    }

    @Test func blockingOverflowIsUnaffectedByDonePings() {
        let items = (0..<5).map { item("b\($0)", Int64($0)) }
            + [item("d0", 100, done: true)]
        let selection = PingStackLayout.selectShown(items)
        #expect(selection.overflow == 2)   // 5 blocking - 3 shown, done doesn't add to it
        #expect(selection.shown.allSatisfy { !$0.isDone })
    }

    @Test func doneNeverDisplacesAFullBlockingStack() {
        // At the cap already: no room left, so no done ping shows at all —
        // not even one older than every approval.
        let items = (0..<3).map { item("b\($0)", Int64(100 + $0)) } + [item("old-done", 0, done: true)]
        let selection = PingStackLayout.selectShown(items)
        #expect(selection.shown.map(\.id) == ["b0", "b1", "b2"])
    }

    @Test func doneFillsLeftoverRoomOldestFirst() {
        let items = [item("b0", 0)]
            + [item("d1", 20, done: true), item("d0", 10, done: true)]
        let selection = PingStackLayout.selectShown(items)
        #expect(selection.shown.map(\.id) == ["b0", "d0", "d1"])
    }

    @Test func doneAlwaysOrderedAfterBlockingRegardlessOfAge() {
        // A done ping older than the approval still draws below it — done
        // pings coming and going shouldn't shift an approval's position.
        let items = [item("approval", 100), item("done", 0, done: true)]
        let selection = PingStackLayout.selectShown(items)
        #expect(selection.shown.map(\.id) == ["approval", "done"])
    }

    @Test func layoutPropagatesIsDoneOntoRows() {
        let items = [item("b0", 0), item("d0", 1, done: true)]
        let result = PingStackLayout.layout(items, heights: ["b0": PingStackLayout.collapsedHeight, "d0": PingStackLayout.doneHeight])
        #expect(result.rows.first { $0.id == "b0" }?.isDone == false)
        #expect(result.rows.first { $0.id == "d0" }?.isDone == true)
        #expect(result.rows.first { $0.id == PingStackLayout.overflowID } == nil)
    }
}

@Suite struct DoneFadeTests {
    @Test func visibleBeforeTheFadeWindow() {
        #expect(PingStackLayout.doneVisible(ts: 1_000, nowMs: 1_000 + PingStackLayout.doneFadeMs - 1))
    }

    @Test func notVisibleAtOrPastTheFadeWindow() {
        #expect(!PingStackLayout.doneVisible(ts: 1_000, nowMs: 1_000 + PingStackLayout.doneFadeMs))
        #expect(!PingStackLayout.doneVisible(ts: 1_000, nowMs: 1_000 + PingStackLayout.doneFadeMs + 500))
    }

    @Test func freshlyDoneIsVisible() {
        #expect(PingStackLayout.doneVisible(ts: 5_000, nowMs: 5_000))
    }
}

@Suite struct CollapsedHeightRowThreeTests {
    @Test func plainCollapsedHeightHasNoThirdRow() {
        #expect(PingStackLayout.collapsedHeight(rowThree: false) == PingStackLayout.collapsedHeight)
    }

    @Test func rowThreeAddsExactlyItsOwnHeight() {
        #expect(PingStackLayout.collapsedHeight(rowThree: true)
            == PingStackLayout.collapsedHeight + PingStackLayout.rowThreeHeight)
    }

    @Test func doneHeightIsItsOwnShorterConstant() {
        #expect(PingStackLayout.doneHeight < PingStackLayout.collapsedHeight)
    }
}

/// Regression guard for the row-1 truncation-priority fix: whatever a
/// collapsed row's kind word and buttons need, there has to be some width
/// left over for the session name to draw as a name — not a promise about
/// exact pixels (SwiftUI still lays out the real buttons), just a tripwire
/// for a future row-1 addition that quietly eats the rest of that room.
@Suite struct PingRowOneBudgetTests {
    @Test func approvalRowLeavesRoomForAName() {
        // "· needs approval" + terminal + deny + allow.
        #expect(PingRowOneBudget.fits(kindText: "needs approval", iconButtons: 3))
    }

    @Test func twoOptionQuestionRowLeavesRoomForAName() {
        // "· asks" + terminal + two text option buttons + ✎.
        #expect(PingRowOneBudget.fits(kindText: "asks", iconButtons: 2, textButtons: 2))
    }

    @Test func countAndExpandRowLeavesRoomForAName() {
        // "· asks · 4" + terminal + chevron.
        #expect(PingRowOneBudget.fits(kindText: "asks · 4", iconButtons: 2))
    }

    @Test func doneRowLeavesRoomForAName() {
        // "· done", no buttons at all.
        #expect(PingRowOneBudget.fits(kindText: "done", iconButtons: 0))
    }

    @Test func theBudgetCanActuallyFail() {
        // Proof this check isn't vacuously true: enough buttons genuinely
        // blow it, which is exactly what should catch a future row-1 that
        // grows without anyone revisiting this budget.
        #expect(!PingRowOneBudget.fits(kindText: "needs approval", iconButtons: 8))
    }
}
