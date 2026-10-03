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
        inspect: (NSSplitView) throws -> Void
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
        try inspect(try #require(splitView(in: controller.view)))
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

    /// The centre pane used to be named with `.contain` and an identifier on its SwiftUI content. When
    /// that content was one element, the journey editor's list, SwiftUI merged the two and the list
    /// lost its own identifier. Named on an AppKit group instead, the pane is one element whatever it
    /// holds, and exactly the pane's size, which is what the UI suite measures panels by.
    @Test("A named primary pane is an accessibility group the pane's own size")
    func namedPrimaryPaneIsAGroupThePanesSize() throws {
        let pane = DSSplitPane(
            axis: .vertical,
            isSecondaryPresented: .constant(true),
            secondaryThickness: .constant(150),
            minimumPrimaryThickness: 120,
            minimumSecondaryThickness: 80,
            defaultSecondaryThickness: 150,
            identifier: "named",
            primaryAccessibilityIdentifier: "centerPane"
        ) {
            Color.clear
        } secondary: {
            Color.clear
        }
        try host(pane) { split in
            func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
                abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
                    && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
            }
            let named = views(in: split).filter { $0.accessibilityIdentifier() == "centerPane" }
            #expect(named.count == 1, "One view carries the pane's name")
            let group = try #require(named.first)
            #expect(group.isAccessibilityElement())
            #expect(group.accessibilityRole() == .group)

            let primary = split.arrangedSubviews[0]
            #expect(group === primary || group.isDescendant(of: primary), "The name is on the primary pane")
            #expect(roughlyEqual(group.convert(group.bounds, to: split), primary.frame),
                    "The group is \(group.convert(group.bounds, to: split)) in a pane of \(primary.frame)")
            // The content fills it, so no part of the pane lies outside the group.
            #expect(group.subviews.count == 1)
            let content = try #require(group.subviews.first)
            #expect(roughlyEqual(content.frame, group.bounds), "The content is \(content.frame) in \(group.bounds)")
        }
    }

    @Test("A collapsed pane leaves no seam behind")
    func collapsedPaneHidesItsDivider() throws {
        let pane = DSSplitPane(
            axis: .vertical,
            isSecondaryPresented: .constant(false),
            secondaryThickness: .constant(150),
            minimumPrimaryThickness: 120,
            minimumSecondaryThickness: 80,
            defaultSecondaryThickness: 150,
            identifier: "collapsed"
        ) {
            Color.clear
        } secondary: {
            Color.clear
        }
        try host(pane) { splitView in
            // Its band draws no seam: left in, it stayed at the bottom edge as a strip of the panel.
            #expect(DSHairlineSplitView.isTrailingPaneCollapsed(in: splitView))
        }
    }
}

