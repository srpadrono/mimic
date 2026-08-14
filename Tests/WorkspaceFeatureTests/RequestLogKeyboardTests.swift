import Foundation
import SwiftUI
import Testing
import Domain
@testable import AppFeatures

/// The request log's keyboard contract.
///
/// The table is a `LazyVStack` of tap targets rather than a `List` — six columns at a fixed row
/// height is not something a `List` draws — so none of this comes for free the way it does in the
/// welcome window's recents list. Every rule below is decided by
/// `RequestLogDrawerView.nextSelection(key:extending:current:anchor:displayOrder:)`, which is pure,
/// and pinned here rather than driven through a window: the interesting cases are all at the edges.
///
/// `nil` throughout means *the table declines the press*, which is not the same as "nothing
/// happens": the view returns `.ignored` and the event goes on to whatever is behind it, so an
/// arrow at the end of the list still scrolls.
@Suite("Request log keyboard")
@MainActor
struct RequestLogKeyboardTests {

    /// Four rows, in the order the table is drawing them — which is the filtered, sorted order, not
    /// the log's own. `nonisolated` so it can stand as a default argument below without carrying the
    /// suite's actor with it.
    nonisolated static let rows: [UUID] = [UUID(), UUID(), UUID(), UUID()]

    private func press(
        _ key: RequestLogDrawerView.SelectionKey,
        extending: Bool = false,
        current: Set<UUID>,
        anchor: UUID? = nil,
        displayOrder: [UUID] = RequestLogKeyboardTests.rows
    ) -> RequestLogDrawerView.KeyboardSelection? {
        RequestLogDrawerView.nextSelection(
            key: key,
            extending: extending,
            current: current,
            anchor: anchor,
            displayOrder: displayOrder
        )
    }

    // MARK: - Which keys the table claims

    /// ⌘ is the whole difference between a command and somebody typing. The table holds focus while
    /// this is decided, so a bare "a" has to pass straight through.
    @Test("Only the keys the table claims are handled, and ⌘ is what makes A one of them")
    func mapsOnlyItsOwnKeys() {
        #expect(RequestLogDrawerView.selectionKey(key: .downArrow, modifiers: []) == .moveDown)
        #expect(RequestLogDrawerView.selectionKey(key: .upArrow, modifiers: .shift) == .moveUp)
        #expect(RequestLogDrawerView.selectionKey(key: .return, modifiers: []) == .activate)
        #expect(RequestLogDrawerView.selectionKey(key: .escape, modifiers: []) == .clear)
        #expect(RequestLogDrawerView.selectionKey(key: "a", modifiers: .command) == .selectAll)

        #expect(RequestLogDrawerView.selectionKey(key: "a", modifiers: []) == nil)
        #expect(RequestLogDrawerView.selectionKey(key: .leftArrow, modifiers: []) == nil)
        #expect(RequestLogDrawerView.selectionKey(key: .space, modifiers: []) == nil)
    }

    // MARK: - Moving

    /// An AppKit table answers its first arrow key by selecting at the near end rather than by doing
    /// nothing until something has been clicked, which is what makes the list reachable from the
    /// keyboard at all.
    @Test("An arrow with nothing selected starts at the near end of the list")
    func firstArrowStartsAtTheNearEnd() throws {
        let down = try #require(press(.moveDown, current: []))
        #expect(down.change.selection == [Self.rows[0]])
        #expect(down.change.anchor == Self.rows[0])
        #expect(down.reveal == Self.rows[0])

        let up = try #require(press(.moveUp, current: []))
        #expect(up.change.selection == [Self.rows[3]])
        #expect(up.change.anchor == Self.rows[3])
    }

    @Test("A plain arrow moves the selection one row and takes the anchor with it")
    func plainArrowMovesOneRow() throws {
        let down = try #require(press(.moveDown, current: [Self.rows[1]], anchor: Self.rows[1]))
        #expect(down.change.selection == [Self.rows[2]])
        #expect(down.change.anchor == Self.rows[2])
        #expect(down.reveal == Self.rows[2])

        let up = try #require(press(.moveUp, current: [Self.rows[2]], anchor: Self.rows[2]))
        #expect(up.change.selection == [Self.rows[1]])
        #expect(up.change.anchor == Self.rows[1])
    }

    /// A multi-row selection is pushed from the edge the arrow is pressing against — ↓ from the last
    /// selected row, ↑ from the first — so an arrow after a ⌘-click run continues from the end you
    /// are heading towards rather than from wherever the anchor happens to sit.
    @Test("An arrow leaves a multi-row selection from the edge it is pushing")
    func arrowLeavesFromTheEdgeItPushes() throws {
        let selection: Set<UUID> = [Self.rows[1], Self.rows[2]]

        let down = try #require(press(.moveDown, current: selection, anchor: Self.rows[1]))
        #expect(down.change.selection == [Self.rows[3]])

        let up = try #require(press(.moveUp, current: selection, anchor: Self.rows[2]))
        #expect(up.change.selection == [Self.rows[0]])
    }

    @Test("An arrow at the end of the list is declined rather than swallowed")
    func arrowAtTheEndIsDeclined() {
        #expect(press(.moveDown, current: [Self.rows[3]], anchor: Self.rows[3]) == nil)
        #expect(press(.moveUp, current: [Self.rows[0]], anchor: Self.rows[0]) == nil)
    }

    @Test("An empty table handles no key at all")
    func emptyTableHandlesNothing() {
        for key in [RequestLogDrawerView.SelectionKey.moveDown, .moveUp, .activate, .selectAll, .clear] {
            #expect(press(key, current: [], displayOrder: []) == nil)
        }
    }

    // MARK: - Extending

    /// ⇧↓ ⇧↓ has to grow the range a row at a time. Measured from the anchor instead, the second
    /// press would re-add the row the first one took and the range would never move.
    @Test("⇧-arrow grows the range a row at a time, keeping the anchor")
    func shiftArrowGrowsTheRange() throws {
        let first = try #require(press(.moveDown, extending: true, current: [Self.rows[0]], anchor: Self.rows[0]))
        #expect(first.change.selection == [Self.rows[0], Self.rows[1]])
        #expect(first.change.anchor == Self.rows[0])
        #expect(first.reveal == Self.rows[1])

        let second = try #require(
            press(.moveDown, extending: true, current: first.change.selection, anchor: first.change.anchor)
        )
        #expect(second.change.selection == [Self.rows[0], Self.rows[1], Self.rows[2]])
        #expect(second.change.anchor == Self.rows[0])
    }

    /// The selection can be set from outside this table — picking a request out of an endpoint's
    /// traffic list does exactly that — so the anchor can name a row that is no longer in it. The
    /// ⇧-click arm guards the same staleness.
    @Test("A stale anchor falls back to the edge the range grew from")
    func staleAnchorFallsBackToTheEdge() throws {
        let extended = try #require(
            press(.moveDown, extending: true, current: [Self.rows[2]], anchor: Self.rows[0])
        )

        #expect(extended.change.selection == [Self.rows[2], Self.rows[3]])
        #expect(extended.change.anchor == Self.rows[2])
    }

    // MARK: - Return

    /// The inspector shows a request only when exactly one row is selected, so collapsing the
    /// selection *is* the keyboard's "open it".
    @Test("Return collapses a multi-row selection onto one row")
    func returnCollapsesTheSelection() throws {
        let collapsed = try #require(
            press(.activate, current: [Self.rows[0], Self.rows[2]], anchor: Self.rows[0])
        )

        #expect(collapsed.change.selection == [Self.rows[2]])
        #expect(collapsed.change.anchor == Self.rows[2])
        #expect(collapsed.reveal == Self.rows[2])
    }

    /// Return must never be a dismiss key: a row alone in the selection is already open in the
    /// inspector, and clearing it there would throw away the thing the press was confirming.
    @Test("Return neither clears a single selection nor invents one")
    func returnIsNeverDestructive() {
        #expect(press(.activate, current: [Self.rows[2]], anchor: Self.rows[2]) == nil)
        #expect(press(.activate, current: []) == nil)
    }

    // MARK: - Select all and clear

    /// "Everything shown", not "everything logged": ⌘A is bounded by the display order, which is what
    /// the method filter, the unmatched toggle and the filter field have already narrowed.
    @Test("⌘A takes every row the filter is showing, and scrolls nowhere")
    func selectAllTakesWhatIsShown() throws {
        let all = try #require(press(.selectAll, current: [Self.rows[1]], anchor: Self.rows[1]))
        #expect(all.change.selection == Set(Self.rows))
        #expect(all.change.anchor == Self.rows[3])
        #expect(all.reveal == nil)

        let filtered = try #require(
            press(.selectAll, current: [], displayOrder: [Self.rows[0], Self.rows[1]])
        )
        #expect(filtered.change.selection == [Self.rows[0], Self.rows[1]])

        // Already whole: nothing to do, and the press goes back to the window.
        #expect(press(.selectAll, current: Set(Self.rows)) == nil)

        // Same size, different rows — which is what a filter change produces, and what a count
        // comparison cannot tell apart from "already whole". Declining here left ⌘A doing nothing
        // with nothing to say why.
        let sameSize = try #require(
            press(
                .selectAll,
                current: [Self.rows[2], Self.rows[3]],
                displayOrder: [Self.rows[0], Self.rows[1]]
            )
        )
        #expect(sameSize.change.selection == [Self.rows[0], Self.rows[1]])
    }

    @Test("Escape clears the selection, and is declined when there is nothing to clear")
    func escapeClearsTheSelection() throws {
        let cleared = try #require(press(.clear, current: [Self.rows[1]], anchor: Self.rows[1]))
        #expect(cleared.change.selection.isEmpty)
        #expect(cleared.change.anchor == nil)
        #expect(cleared.reveal == nil)

        #expect(press(.clear, current: []) == nil)
    }
}
