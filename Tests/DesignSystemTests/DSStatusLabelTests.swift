import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// `DSStatusLabel` is the one way a status is drawn: a dot and the code in one colour, never a fill.
/// Its colours are pinned in `DSColorsTests` and measured in `DSContrastTests`; these tests hold the
/// geometry a row relies on, which is where the filled pill it replaced went wrong.
@Suite("DSStatusLabel")
@MainActor
struct DSStatusLabelTests {
    /// The same harness `DSComponentRenderingTests` hosts every component through, including the
    /// run-loop turn that lets `NSHostingController` settle before `fittingSize` is read.
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 240, height: 60),
        wait: TimeInterval = 0.1
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    /// A row must not change height when its endpoint starts failing, and a transport failure sits
    /// in the same slot as a code.
    @Test("A status label is one height whatever it reports")
    func oneHeightForEveryStatus() {
        let ok = render(DSStatusLabel(statusCode: 200))
        let others = [
            render(DSStatusLabel(statusCode: 302)),
            render(DSStatusLabel(statusCode: 404)),
            render(DSStatusLabel(statusCode: 500)),
            render(DSStatusLabel(statusCode: nil)),
            render(DSStatusLabel(statusCode: nil, reason: "timeout 30000ms")),
            render(DSStatusLabel(statusCode: 200, reason: "OK")),
        ]
        for size in others {
            #expect(size.height == ok.height)
        }
    }

    /// No status class is filled any more, so three digits are three digits: a 500 is exactly as
    /// wide as a 200. The pill this replaced filled 4xx and 5xx and was wider by its inset there,
    /// which moved everything after it in a column of mixed codes.
    @Test("Codes of one length take one width, whatever their class")
    func codesShareOneWidth() {
        let ok = render(DSStatusLabel(statusCode: 200))
        #expect(render(DSStatusLabel(statusCode: 302)).width == ok.width)
        #expect(render(DSStatusLabel(statusCode: 404)).width == ok.width)
        #expect(render(DSStatusLabel(statusCode: 500)).width == ok.width)
    }

    @Test("A reason phrase follows the code on the same line")
    func reasonFollowsTheCode() {
        let bare = render(DSStatusLabel(statusCode: 404))
        let phrased = render(DSStatusLabel(statusCode: 404, reason: "Not Found"))
        #expect(phrased.width > bare.width)
        #expect(phrased.height == bare.height)
    }

    /// The dot is a 7pt circle 6pt before the text; a label drawn without it gives both back.
    @Test("The dot costs 13pt of width and nothing else")
    func dotGeometry() {
        let withDot = render(DSStatusLabel("Running", color: DSColors.success))
        let withoutDot = render(DSStatusLabel("Running", color: DSColors.success, showsDot: false))
        #expect(withDot.width - withoutDot.width == 13)
        #expect(withDot.height >= withoutDot.height)
    }

    /// A focused navigator's selected row draws the code without its dot; the code keeps its place.
    @Test("A code can drop its dot")
    func codeWithoutDot() {
        let withDot = render(DSStatusLabel(statusCode: 503))
        let withoutDot = render(DSStatusLabel(statusCode: 503, showsDot: false))
        #expect(withDot.width - withoutDot.width == 13)
    }

    /// The navigator draws its code at 11pt, so the compact label is narrower than a table's and
    /// never taller.
    @Test("A compact code is smaller than a regular one")
    func compactCode() {
        let regular = render(DSStatusLabel(statusCode: 503))
        let compact = render(DSStatusLabel(statusCode: 503, size: .compact))
        #expect(compact.width < regular.width)
        #expect(compact.height <= regular.height)
    }
}
