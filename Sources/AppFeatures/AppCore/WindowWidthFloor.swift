import AppKit
import SwiftUI

/// Keeps the window from getting narrower than `width`, whatever its panels would allow.
///
/// SwiftUI gives the window the minimum its content asks for. The workspace's content only asked for
/// a usable width while the inspector was open: with the inspector hidden, or a request taking over
/// the centre column, the window shrank until the editor vanished and the toolbar fell into AppKit's
/// overflow chevron.
///
/// Applied to the window rather than as a `.frame(minWidth:)` in the view tree. A minimum in the tree
/// becomes a constraint inside the split views: placed on the centre column it made dragging the
/// inspector's divider widen the window, and placed around the split views it sent AppKit into an
/// endless constraint pass — "more Update Constraints in Window passes than there are views" — as
/// panels collapsed. The window's own minimum is outside that system, so it cannot feed it.
struct WindowWidthFloor: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> FloorView { FloorView() }

    func updateNSView(_ view: FloorView, context: Context) {
        view.width = width
        view.apply()
    }

    static func dismantleNSView(_ view: FloorView, coordinator: ()) {
        view.restore()
    }

    /// The content minimum to set: SwiftUI's own, widened to the floor. Pure, for testing.
    nonisolated static func raised(_ minimum: CGSize, toWidth width: CGFloat) -> CGSize {
        CGSize(width: max(minimum.width, width), height: minimum.height)
    }

    final class FloorView: NSView {
        var width: CGFloat = 0
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            // SwiftUI rewrites the content minimum whenever its content's minimum changes; raise it
            // again each time, after SwiftUI's own write has landed.
            observation = window.observe(\.contentMinSize) { [weak self] _, _ in
                DispatchQueue.main.async { self?.apply() }
            }
            apply()
        }

        func apply() {
            guard let window, width > 0 else { return }
            let raised = WindowWidthFloor.raised(window.contentMinSize, toWidth: width)
            guard raised != window.contentMinSize else { return }
            window.contentMinSize = raised
        }

        /// Gives the welcome screen, which shares the window, back a minimum of its own.
        func restore() {
            observation = nil
        }
    }
}
