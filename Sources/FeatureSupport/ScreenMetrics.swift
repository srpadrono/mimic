import AppKit

/// How tall a screen is for a section's sheet, which sizes itself from it.
///
/// The import review, the backend settings and the journey step sheet each cap their height at the
/// visible screen, so a compact display keeps their footers reachable. They used to read
/// `NSScreen.main` directly. A UI test launch pins the window to CI's 1024×677 visible frame
/// (`ScreenGeometry` in AppFeatures), but a section cannot reach that, and the environment does not
/// cross the split pane's hosting controllers. So on a 1080p Mac these sheets opened at their design
/// height, taller than the pinned window, while on CI they were capped from 677pt: content that
/// scrolled on CI was all on screen locally.
///
/// The app sets ``pinnedVisibleHeight`` once at startup from the same pin. It exists only in Debug
/// builds and is `nil` on any launch that is not a pinned UI test, so every other launch reads the
/// screen's own visible frame, exactly as before.
public enum ScreenMetrics {
    #if DEBUG
    /// The pinned screen's visible height on a UI test launch, or `nil`.
    public static var pinnedVisibleHeight: CGFloat?
    #endif

    /// The visible height of `screen`, or of the pinned screen inside it, or `nil` without a screen,
    /// so each caller keeps its own fallback.
    public static func visibleHeight(of screen: NSScreen?) -> CGFloat? {
        guard let real = screen?.visibleFrame.height else { return nil }
        #if DEBUG
        return visibleHeight(real: real, pinned: pinnedVisibleHeight)
        #else
        return real
        #endif
    }

    /// `pinned`, never taller than the `real` height, or `real` when nothing is pinned. The same
    /// clamp `ScreenGeometry.pinnedFrame` applies to the window. Pure so it is testable without a
    /// screen.
    nonisolated static func visibleHeight(real: CGFloat, pinned: CGFloat?) -> CGFloat {
        guard let pinned else { return real }
        return min(pinned, real)
    }
}
