import Testing
@testable import AppFeatures

@Suite("Navigation history")
struct NavigationHistoryTests {

    // MARK: - Empty

    @Test("A fresh history has nowhere to go")
    func emptyHistoryHasNoMoves() {
        var history = NavigationHistory<String>()

        #expect(history.current == nil)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)

        let back = history.goBack()
        let forward = history.goForward()

        #expect(back == nil)
        #expect(forward == nil)
    }

    @Test("The first visit is somewhere you cannot go back from")
    func firstVisitIsTheFloor() {
        var history = NavigationHistory<String>()
        history.visit("endpoints")

        #expect(history.current == "endpoints")
        // One entry is a position, not a trail: there is nothing behind it and nothing ahead.
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    // MARK: - Back and forward

    @Test("Going back returns the previous item")
    func goesBackToPreviousItem() {
        var history = NavigationHistory<String>()
        history.visit("endpoints")
        history.visit("journeys")

        #expect(history.canGoBack)

        let previous = history.goBack()

        #expect(previous == "endpoints")
        #expect(history.current == "endpoints")
        #expect(!history.canGoBack)
    }

    @Test("Forward retraces the step back")
    func goesForwardAfterBack() {
        var history = NavigationHistory<String>()
        history.visit("endpoints")
        history.visit("journeys")
        history.goBack()

        #expect(history.canGoForward)

        let next = history.goForward()

        #expect(next == "journeys")
        #expect(history.current == "journeys")
        #expect(!history.canGoForward)

        // Past the end of the trail there is nothing to retrace, and the cursor must not drift.
        let past = history.goForward()

        #expect(past == nil)
        #expect(history.current == "journeys")
    }

    // MARK: - Truncation

    @Test("A new visit drops everything ahead of it")
    func newVisitTruncatesForwardEntries() {
        var history = NavigationHistory<String>()
        history.visit("a")
        history.visit("b")
        history.visit("c")
        history.goBack()

        #expect(history.canGoForward)

        history.visit("d")

        // "c" is gone: you left the trail at "b", so forward now means "d" or nothing.
        #expect(history.current == "d")
        #expect(!history.canGoForward)

        let previous = history.goBack()

        #expect(previous == "b")
    }

    @Test("Re-visiting the current item changes nothing")
    func revisitingCurrentItemIsANoOp() {
        var history = NavigationHistory<String>()
        history.visit("a")
        history.visit("b")
        history.goBack()

        // Clicking the row that is already selected — which the app also does to itself on every
        // re-selection. If this stacked an entry it would both duplicate "a" and throw away "b".
        history.visit("a")

        #expect(history.current == "a")
        #expect(!history.canGoBack)
        #expect(history.canGoForward)

        let next = history.goForward()

        #expect(next == "b")
    }

    @Test("Repeating a visit does not stack duplicates")
    func repeatedVisitsDoNotAccumulate() {
        var history = NavigationHistory<String>()
        history.visit("a")
        history.visit("a")
        history.visit("a")

        #expect(history.current == "a")
        #expect(!history.canGoBack)
    }

    // MARK: - Capacity

    @Test("The history keeps the 50 most recent entries, oldest first out")
    func capsStoredHistoryAtFifty() {
        var history = NavigationHistory<Int>()
        for step in 1...51 {
            history.visit(step)
        }

        #expect(history.current == 51)

        // 51 visits into a 50-entry history: the first is gone, so walking all the way back lands
        // on the second and stops there rather than on 1.
        var steps = 0
        while history.canGoBack {
            history.goBack()
            steps += 1
        }

        #expect(steps == NavigationHistory<Int>.capacity - 1)
        #expect(history.current == 2)
        #expect(!history.canGoBack)
    }

    @Test("Dropping the oldest entry leaves the cursor where it was")
    func trimmingDoesNotMoveTheCursor() {
        var history = NavigationHistory<Int>()
        for step in 1...80 {
            history.visit(step)
        }

        // The trim shifts every index down by one; if it did not shift the cursor with them, the
        // bar would show an item you visited 30 moves ago.
        #expect(history.current == 80)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)

        let previous = history.goBack()

        #expect(previous == 79)
    }
}
