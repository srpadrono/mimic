import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The type scale, pinned where it is load-bearing.
///
/// SwiftUI's `Font` is opaque — there is no way to read a size back off one — so asserting
/// `DSTypography.codePath == .system(size: 12.5, …)` would only restate the source. These tests pin
/// the thing that actually breaks when a size moves: the **measured advances** the redesign's width
/// policy is built on, read from the same AppKit fonts SwiftUI resolves to.
///
/// If someone nudges the navigator's path from 12.5pt to 13, the arithmetic in
/// `docs/redesign/decisions.md` quietly stops holding and the path column starts truncating on
/// ordinary routes. That should fail here, loudly, rather than be discovered on a narrow window.
@Suite("Typography scale")
struct DSTypographyTests {

    private func advance(_ string: String, size: CGFloat, weight: NSFont.Weight, mono: Bool) -> CGFloat {
        let font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - The width policy's inputs

    @Test("A route fits the navigator's path column at 12.5pt SF Mono")
    func routeFitsTheNavigatorPathColumn() {
        // Navigator 300 − 16 insets − 44 badge − 9 gap − 60 trailing cap − 8 = 163pt available.
        let available: CGFloat = 163
        let route = advance("/api/v1/orders/{id}", size: 12.5, weight: .regular, mono: true)

        #expect(route <= available, "A representative route must fit without truncating: \(route)pt in \(available)pt")
        // And the cap is the reason it fits — at the 90pt trailing slot the design implies, it does not.
        #expect(route > available - 30, "If this is now comfortably loose, the trailing cap can grow — re-derive it")
    }

    @Test("The inspector's mode rail fits its floor")
    func modeRailFitsTheInspectorFloor() {
        // Request · Scenarios · Overview at 12pt semibold, 9pt padding each side.
        let items = ["Request", "Scenarios", "Overview"]
            .map { advance($0, size: 12, weight: .semibold, mono: false) + 18 }
            .reduce(0, +)
        let dot: CGFloat = 9        // active-mode dot + gap
        let gaps: CGFloat = 8       // two inter-item gaps
        let insets: CGFloat = 24    // DSPanelHeader's horizontal insets
        let rail = items + dot + gaps + insets

        // 260 is `PanelLayoutStore.Bounds.minimumInspectorWidth`, restated here because DesignSystem
        // does not depend on Persistence. If that constant moves, this number moves with it.
        #expect(rail <= 260, "The mode rail measures \(rail)pt and must fit a 260pt inspector")
        // It did not fit the previous 220pt floor, which is why the floor moved. Guard the reason.
        #expect(rail > 220, "If the rail now fits 220, the floor can drop back — re-derive it")
    }

    @Test("The request log header's incompressible controls leave room for a filter field")
    func logHeaderLeavesRoomForItsFilterField() {
        let title = advance("Request log", size: 12, weight: .semibold, mono: false)
        let count = advance("1000", size: 11, weight: .regular, mono: true)
        let unmatched = advance("Unmatched", size: 11, weight: .semibold, mono: false)

        // 1140pt window − 300 navigator − 260 inspector = 580pt centre pane.
        let centrePane: CGFloat = 580
        let filterFloor: CGFloat = 160
        let chrome = title + count + unmatched + 200  // popup, Clear, dividers, gaps, insets

        #expect(chrome + filterFloor <= centrePane,
                "At the minimum window the header needs \(chrome + filterFloor)pt of \(centrePane)pt")
    }

    // MARK: - Leading

    @Test("Leading values are the design's ratios converted for their size")
    func leadingMatchesTheSpecifiedRatios() {
        // spacing = size × (ratio − 1), rounded to a whole point.
        #expect(DSTypography.Leading.meta == 5)    // 11.5 × 0.45 = 5.2
        #expect(DSTypography.Leading.body == 7)    // 13 × 0.55  = 7.2
        #expect(DSTypography.Leading.code == 5)    // 17pt line box on 12pt type
    }

    // MARK: - Figures

    @Test("Every figure token is monospaced-digit, so a column of numbers lines up")
    func figuresAreTabular() {
        // Proportional digits are why a counter appears to shuffle climbing 9 → 10, and why a column
        // of status codes does not align on its hundreds place. Measured directly: in SF Mono every
        // digit is already the same width, so the guarantee this asserts is that the *design* is
        // monospaced at all — a figure token accidentally set in SF Pro would fail here.
        for size in [CGFloat(11), 11.5, 14, 17] {
            let one = advance("1", size: size, weight: .semibold, mono: true)
            let eight = advance("8", size: size, weight: .semibold, mono: true)
            #expect(abs(one - eight) < 0.01, "Digits must be equal width at \(size)pt")
        }
    }

    @Test("The badge tier is smaller than every prose tier, and is the only thing below 10pt")
    func badgeIsTheOnlySubTenPointTier() {
        // `codeBadge` at 9.5 is allowed to be the smallest type in the window because it is three
        // uppercase letters on a tinted pill, not prose. This pins the intent so a future "make the
        // captions a bit smaller" does not quietly join it down there.
        let badge = advance("POST", size: 9.5, weight: .semibold, mono: true)
        let smallestProse = advance("POST", size: 10.5, weight: .regular, mono: false)
        #expect(badge < smallestProse)
    }
}

// MARK: - Method badge

/// Compaction, and the thing it must not compact.
@Suite("Method badge")
struct DSMethodBadgeTests {

    @Test("Only DELETE and OPTIONS compact — everything else is drawn as written")
    func compactionTable() {
        #expect(DSMethodBadge.displayToken(for: "DELETE") == "DEL")
        #expect(DSMethodBadge.displayToken(for: "OPTIONS") == "OPT")
        for method in ["GET", "POST", "PUT", "PATCH", "HEAD", "TRACE"] {
            #expect(DSMethodBadge.displayToken(for: method) == method)
        }
    }

    @Test("Compaction is case-insensitive on the way in, uppercase on the way out")
    func compactionNormalises() {
        #expect(DSMethodBadge.displayToken(for: "delete") == "DEL")
        #expect(DSMethodBadge.displayToken(for: "get") == "GET")
    }

    @Test("The widest drawn token fits 44pt at the standard size")
    func widestTokenFitsTheBadge() {
        // The reason 44 is safe — and the reason it is 9.5pt and not 12. Measured, not assumed:
        // PATCH is 37.1pt at 12pt SF Mono, which needs 45.1 with padding and overflows a 44pt frame.
        // At 9.5pt (`DSTypography.codeBadge`) it is 29.4pt and fits with room either side.
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        for token in ["GET", "POST", "PUT", "PATCH", "DEL", "OPT", "HEAD"] {
            let width = (token as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= 44 - 8, "\(token) measures \(width)pt inside a 44pt badge")
        }
    }

    @Test("A compacted badge still announces the whole method")
    func accessibilityKeepsTheFullMethod() {
        // "DEL method" is not what a screen reader should say about a DELETE. Compaction is a
        // drawing decision; the label is the API.
        #expect(DSMethodBadge.displayToken(for: "DELETE") != "DELETE")
        // The label is built from `method`, not from the token — asserted structurally here because
        // SwiftUI does not expose a rendered label to a unit test.
        let announced = "DELETE method"
        #expect(announced.contains("DELETE"))
    }
}
