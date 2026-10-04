import AppKit
import SwiftUI

/// Keeps the window inside its screen's visible frame when the content, not the person, resizes it.
///
/// The welcome screen and the workspace share one window. The workspace needs more height than the
/// welcome screen, so opening a project grows the window, and AppKit grows it downward from a fixed
/// top edge. On a 1024×768 display that pushed the bottom of the window under the Dock: the
/// navigator's footer, which carries Add endpoint and the add-journey menu, was drawn but could not
/// be clicked, and a click aimed at it landed on a Dock icon instead. A later launch hid the problem
/// because AppKit constrains a restored frame to the screen.
///
/// Only resizes the person did not make are corrected (`inLiveResize` is false), so dragging an edge
/// still behaves exactly as it does in any other window. On a UI test launch the visible frame is
/// the pinned screen's (``ScreenGeometry``), so the window fits CI's display on every Mac.
struct WindowScreenFit: NSViewRepresentable {
    func makeNSView(context: Context) -> FittingView { FittingView() }
    func updateNSView(_ nsView: FittingView, context: Context) {}

    /// The frame `window` should take so it lies inside `visible`, or `nil` when it already does.
    ///
    /// Moves the window first and shrinks it only when it is taller or wider than the visible frame,
    /// never below `minimum`. Pure so the arithmetic is testable without a window.
    nonisolated static func fittedFrame(_ frame: CGRect, visible: CGRect, minimum: CGSize) -> CGRect? {
        var fitted = frame
        if fitted.height > visible.height {
            fitted.size.height = max(visible.height, minimum.height)
        }
        if fitted.width > visible.width {
            fitted.size.width = max(visible.width, minimum.width)
        }
        if fitted.minY < visible.minY { fitted.origin.y = visible.minY }
        if fitted.maxY > visible.maxY { fitted.origin.y = visible.maxY - fitted.height }
        if fitted.minX < visible.minX { fitted.origin.x = visible.minX }
        if fitted.maxX > visible.maxX { fitted.origin.x = visible.maxX - fitted.width }
        return fitted == frame ? nil : fitted
    }

    final class FittingView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            #if DEBUG
            // Before the fit below can move the window: AppKit would record that frame for the next
            // launch, and in a UI test run it would be the developer's own Mimic that reopened there.
            UITestSupport.stopFrameAutosave(window)
            #endif
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            fitWindow()
        }

        @objc private func windowDidResize(_ notification: Notification) {
            fitWindow()
        }

        private func fitWindow() {
            guard let window, !window.inLiveResize, !window.styleMask.contains(.fullScreen),
                  let visible = ScreenGeometry.visibleFrame(of: window.screen),
                  let fitted = WindowScreenFit.fittedFrame(window.frame, visible: visible, minimum: minimumFrameSize(of: window))
            else { return }
            window.setFrame(fitted, display: true)
        }

        /// SwiftUI publishes its content's minimum as `contentMinSize`; shrinking past it would only
        /// have SwiftUI grow the window straight back.
        private func minimumFrameSize(of window: NSWindow) -> CGSize {
            let content = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
            return CGSize(width: max(content.width, window.minSize.width),
                          height: max(content.height, window.minSize.height))
        }
    }
}
