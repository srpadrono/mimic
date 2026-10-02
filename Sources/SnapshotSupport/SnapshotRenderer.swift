import AppKit
import SwiftUI

/// Draws a SwiftUI view the way a window would, into a bitmap of an exact pixel size.
///
/// The view is hosted in an `NSHostingView` inside an off-screen window rather than drawn with
/// `ImageRenderer`, because `ImageRenderer` leaves AppKit-backed controls (text views, pop-up
/// buttons, split views) blank, and most of Mimic's sections contain one.
@MainActor
public enum SnapshotRenderer {
    public enum Appearance: String, CaseIterable, Sendable, Identifiable {
        case dark
        case light

        public var id: String { rawValue }

        var nsAppearance: NSAppearance? {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }

        public var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    /// Renders `view` at `size` points and `scale` pixels per point.
    ///
    /// - Parameters:
    ///   - settle: how long to let the run loop turn before drawing, so `onAppear`, `task` and
    ///     AppKit's own deferred layout have happened.
    ///   - focusesList: draws the view in the key window with its first list focused, the state a
    ///     design draws a sidebar in. Off-screen windows are never key, so a list otherwise shows
    ///     the grey selection of a list that doesn't have focus.
    public static func render<Content: View>(
        _ view: Content,
        size: CGSize,
        appearance: Appearance,
        scale: CGFloat = 2,
        settle: TimeInterval = 0.1,
        focusesList: Bool = false
    ) -> CGImage? {
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.colorScheme)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window: NSWindow = focusesList
            ? KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.nsAppearance
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        if focusesList {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            if let list = firstTableView(in: host) {
                window.makeFirstResponder(list)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        // A rep whose point size is smaller than its pixel size draws at that ratio, which is what
        // makes a 2x image on a 1x display.
        bitmap.size = size
        var drawn: CGImage?
        appearance.nsAppearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            drawn = bitmap.cgImage
        }
        return drawn
    }

    /// The first table or outline view under `view`, depth first: the view a SwiftUI `List` draws.
    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTableView(in: subview) { return table }
        }
        return nil
    }

    /// A window that reports itself key, so controls draw as they do in the window you're using.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }
}
