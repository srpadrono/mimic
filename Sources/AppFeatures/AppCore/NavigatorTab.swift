import Foundation

/// Which list the sidebar is showing.
///
/// Xcode keeps nine navigators — files, issues, tests, breakpoints — in one panel behind an icon
/// strip, and never opens a window for any of them. Mimic had one list and a *separate window* for
/// journeys, which is the worst placement available for the feature: a journey overrides what every
/// endpoint returns, so it is the most consequential thing in the app, and it was the one thing you
/// could not see beside your endpoints. The toolbar's journey indicator existed to compensate for
/// that distance.
///
/// That window is gone. Keeping both was worse than either: the tab and the window showed the same
/// list, so "Show Journeys" put a duplicate of the panel you were already looking at on top of it,
/// and neither copy was obviously the real one. A journey rewrites what every endpoint returns, so
/// the navigator — next to the endpoints — is the home that earns it.
enum NavigatorTab: String, CaseIterable, Identifiable, Sendable {
    case endpoints
    case journeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .endpoints: "Endpoints"
        case .journeys: "Journeys"
        }
    }

    /// The canonical glyph for each noun, and the only place in `AppFeatures` either is chosen.
    ///
    /// Every empty state that says a thing is absent or unselected — "No journeys", "No endpoint
    /// selected" — reads from here rather than naming a symbol of its own. Five of them used to name
    /// their own, and they disagreed: journeys were `arrow.triangle.branch` in the tab strip and in
    /// the centre pane but `list.number` in both journey navigators, so the "No journeys" panel was
    /// showing a list glyph one row below a tab whose glyph was a branch — and `list.number` is close
    /// enough to the endpoints tab's `list.bullet.indent` to read as the *other* tab's icon.
    ///
    /// The breadcrumb's journey crumb was the one that had drifted back: it spelled
    /// `arrow.triangle.branch` out again, one bar below the tab it was repeating, so the two agreed
    /// only for as long as nobody edited this property. It reads from here now.
    ///
    /// An empty state about an event that has not happened yet keeps its own glyph. "No requests yet"
    /// is about arrival, not about endpoints, so `arrow.down.circle` is right there.
    ///
    /// ```bash
    /// # Both names, everywhere. Prints this file, plus a DesignSystem preview drawing a specimen
    /// # tab strip — that module cannot import this type, and is not choosing this app's tab icons.
    /// grep -rn 'arrow\.triangle\.branch\|list\.bullet\.indent' Sources
    /// ```
    var systemImage: String {
        switch self {
        case .endpoints: "list.bullet.indent"
        case .journeys: "arrow.triangle.branch"
        }
    }

    /// What the tab's icon button says out loud, and what its tooltip reads.
    var help: String {
        switch self {
        case .endpoints: "Show endpoints"
        case .journeys: "Show journeys"
        }
    }

    /// `⌘1`, `⌘2` — the same shape of shortcut Xcode gives its navigators.
    var shortcut: Character {
        switch self {
        case .endpoints: "1"
        case .journeys: "2"
        }
    }
}

/// What the centre pane is editing.
///
/// Selecting in a navigator changes the editor, exactly as clicking a file in Xcode's project
/// navigator does. Modelled as one value rather than two optional IDs so the two cannot both be
/// "selected" and leave the pane guessing which to show.
enum CenterPaneContent: Equatable, Sendable {
    case endpoint(UUID?)
    case journey(UUID?)

    static func forTab(_ tab: NavigatorTab, endpointID: UUID?, journeyID: UUID?) -> CenterPaneContent {
        switch tab {
        case .endpoints: .endpoint(endpointID)
        case .journeys: .journey(journeyID)
        }
    }
}
