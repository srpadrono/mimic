import Foundation

/// Moves through visible navigator items, skipping group headings and collapsed rows.
enum NavigatorKeyboardSelection {
    static func moved(from current: UUID?, by offset: Int, through visibleIDs: [UUID]) -> UUID? {
        guard !visibleIDs.isEmpty else { return nil }
        let start = current.flatMap { visibleIDs.firstIndex(of: $0) }
            ?? (offset > 0 ? -1 : visibleIDs.count)
        let target = min(max(start + offset, 0), visibleIDs.count - 1)
        return visibleIDs[target]
    }
}
