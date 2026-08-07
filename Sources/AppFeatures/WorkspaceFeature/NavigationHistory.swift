import Foundation

/// Back/forward history for the centre pane, in the shape a browser uses.
///
/// `nonisolated` because this is arithmetic over an array: it has no actor affinity, and keeping it
/// off the main actor means it can be exercised as a plain value in tests rather than through a view.
///
/// Two rules make it feel like a browser rather than an undo stack: a new visit throws away
/// everything ahead of the cursor, and re-visiting the item you are already on does nothing at all.
/// Without the second rule, clicking the selected sidebar row — which the app does on every
/// re-selection, including the ones it triggers itself — would stack duplicates until "back" walked
/// you through the same endpoint a dozen times.
///
/// This used to live at the bottom of `BreadcrumbJumpBar.swift`, which is where it was written. The
/// jump bar was deleted so the four panel headers could share one baseline; the history it drove
/// outlived it unchanged, and its tests never referenced the view at all.
nonisolated struct NavigationHistory<Item: Equatable>: Equatable {
    /// Enough to retrace a working session, small enough that the array never becomes a leak.
    static var capacity: Int { 50 }

    /// Where you are. `nil` until something has been visited.
    private(set) var current: Item?

    private var entries: [Item] = []
    /// Index into `entries`; `-1` while the history is empty.
    private var index: Int = -1

    init() {}

    var canGoBack: Bool { index > 0 }

    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Records a move to `item`. A new visit truncates any forward entries — the standard rule.
    /// Visiting the item you are already on is a no-op, so re-selecting does not stack duplicates.
    mutating func visit(_ item: Item) {
        guard current != item else { return }

        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }

        entries.append(item)

        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }

        index = entries.count - 1
        refreshCurrent()
    }

    @discardableResult
    mutating func goBack() -> Item? {
        guard canGoBack else { return nil }
        index -= 1
        refreshCurrent()
        return current
    }

    @discardableResult
    mutating func goForward() -> Item? {
        guard canGoForward else { return nil }
        index += 1
        refreshCurrent()
        return current
    }

    private mutating func refreshCurrent() {
        current = entries.indices.contains(index) ? entries[index] : nil
    }
}
