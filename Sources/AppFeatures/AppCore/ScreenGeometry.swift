import AppKit

/// The one place window code asks how much of a screen it may use.
///
/// CI's macOS runners have a 1024×768 display, and its visible frame, under the menu bar and above
/// the Dock, is 1024×674. A developer's Mac is usually far larger. Every size the window takes from
/// the screen differed between the two: the test window sizes, the welcome screen's centring, the
/// first workspace's frame and the fit that keeps the window above the Dock. So a layout test that
/// failed on CI passed locally, and the failure could not be reproduced without a CI run.
///
/// A UI test launch pins the screen with `MIMIC_UITEST_SCREEN` (``UITestSupport/pinnedScreenSize``),
/// and every one of those sizes then comes from a frame of that size at the top left of the real
/// one, which on CI is the real visible frame itself. Every other launch gets the screen's own
/// visible frame, exactly as before. Menus, pop-ups and sheets that AppKit places for itself still
/// see the real screen, so near its bottom edge they can open differently on a larger display.
enum ScreenGeometry {
    /// The visible frame of `screen`, or of the pinned screen inside it on a UI test launch.
    ///
    /// Takes the screen rather than a window so each caller keeps its own fallback: the window's
    /// layout reads nothing until the window has a screen, while the test resize commands fall back
    /// to the main screen.
    static func visibleFrame(of screen: NSScreen?) -> CGRect? {
        guard let real = screen?.visibleFrame else { return nil }
        #if DEBUG
        if let pinned = UITestSupport.pinnedScreenSize { return pinnedFrame(pinned, in: real) }
        #endif
        return real
    }

    /// `size` at the top left of `real`, and never larger than it.
    ///
    /// The top left because that is where CI's visible frame starts, under the menu bar, so a window
    /// at a given distance from the top edge is at the same place on both. AppKit's origin is the
    /// bottom left, which puts that edge at `real.maxY`. Pure so the arithmetic is testable without
    /// a screen.
    nonisolated static func pinnedFrame(_ size: CGSize, in real: CGRect) -> CGRect {
        let width = min(size.width, real.width)
        let height = min(size.height, real.height)
        return CGRect(x: real.minX, y: real.maxY - height, width: width, height: height)
    }
}
