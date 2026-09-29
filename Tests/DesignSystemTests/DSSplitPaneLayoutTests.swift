import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// A split pane whose primary pane hugs its content, with a hook for what the content reports.
private struct HuggingPane: View {
    @State var preferred: CGFloat
    /// Called with each height the primary pane is laid out at; returns the content's new extent.
    let reflow: (CGFloat, CGFloat) -> CGFloat

    var body: some View {
        DSSplitPane(
            axis: .vertical,
            isSecondaryPresented: .constant(true),
            secondaryThickness: .constant(150),
            minimumPrimaryThickness: 120,
            minimumSecondaryThickness: 80,
            defaultSecondaryThickness: 150,
            preferredPrimaryThickness: preferred,
            identifier: "hugging"
        ) {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                preferred = reflow(height, preferred)
            }
        } secondary: {
            Color.clear
        }
    }
}

@Suite("DSSplitPane layout", .serialized)
@MainActor
struct DSSplitPaneLayoutTests {
    /// Hosts `view` in a 400×600 window and returns its split view, after `settle` seconds.
    private func host(
        _ view: some View,
        settle: TimeInterval = 0.5,
        inspect: (NSSplitView) -> Void
    ) throws {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 400, height: 600))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        func splitView(in view: NSView) -> NSSplitView? {
            (view as? NSSplitView) ?? view.subviews.lazy.compactMap(splitView).first
        }
        inspect(try #require(splitView(in: controller.view)))
    }

    /// The fit used to be made from `viewDidLayout`, where the pass already running undid it: the
    /// pane stayed on its 120pt minimum while the content asked for 300.
    @Test("The primary pane settles at its content's extent")
    func primaryPaneHugsContent() throws {
        try host(HuggingPane(preferred: 300, reflow: { _, preferred in preferred })) { split in
            #expect(abs(split.arrangedSubviews[0].frame.height - 300) < 1)
        }
    }

    /// Content whose extent depends on the pane it sits in, reduced to its worst case: every height
    /// the pane is laid out at produces the *other* of two extents. Each new extent used to start a
    /// new fit with a fresh retry budget, which is the loop behind the 56-second hang.
    @Test("Content that reflows with its pane cannot keep the divider moving")
    func oscillatingContentSettles() throws {
        var reflows = 0
        let pane = HuggingPane(preferred: 300, reflow: { _, preferred in
            reflows += 1
            return preferred == 300 ? 340 : 300
        })
        try host(pane) { split in
            let settled = reflows
            let height = split.arrangedSubviews[0].frame.height
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            #expect(settled < 10, "the divider chased the content \(settled) times")
            #expect(reflows == settled, "still moving after settling: \(reflows - settled) more reflows")
            #expect(split.arrangedSubviews[0].frame.height == height)
        }
    }
}
