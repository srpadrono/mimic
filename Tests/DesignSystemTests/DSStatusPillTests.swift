import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// `DSStatusPill` exists because six call sites hand-copied one convention and two of them shipped
/// disagreeing about the hardest case. These tests hold the convention where it now lives, so a
/// seventh caller gets it for free and a regression in any arm fails here rather than in a window.
@Suite("DSStatusPill")
@MainActor
struct DSStatusPillTests {
    // MARK: - The failure arm

    /// The divergence the component was extracted to end, asserted on the side that won.
    ///
    /// A request that was failed rather than answered has no status code. `RequestLogTableRow`
    /// spelled that `responseStatusCode ?? 0` and drew a bare grey `0` with no fill — `0` is
    /// outside every class, so `httpStatusColor(for: 0)` returns `.secondary` — while
    /// `EndpointTrafficRow` drew a filled destructive em dash and defended it in a comment. Every
    /// line here fails against the `?? 0` spelling: the text, the colour and the fill are all
    /// different, so re-introducing it inside the component cannot pass.
    @Test("No status code at all is a failure: a filled destructive em dash, never a grey 0")
    func nilStatusIsTheFailureArm() {
        let pill = DSStatusPill(statusCode: nil)
        #expect(pill.text == "\u{2014}")
        #expect(pill.text != "0")
        #expect(pill.color == DSColors.destructiveText)
        #expect(pill.isFilled)
    }

    /// The named-failure arm is the same styling with the failure's own word in it.
    @Test("A failure label wears the failure arm's styling")
    func failureLabelArm() {
        let pill = DSStatusPill(failureLabel: "timeout 30000ms")
        #expect(pill.text == "timeout 30000ms")
        #expect(pill.color == DSColors.destructiveText)
        #expect(pill.isFilled)
    }

    // MARK: - The fill gate

    /// "A filled colour swatch is for something that needs attention" — and, since the 3xx
    /// measurement in `DSContrastTests.redirectTextIsReadableButItsFillIsNot`, a contrast rule:
    /// the gate living here is what keeps a filled 3xx unreachable in the window.
    @Test("Only a 4xx or 5xx is filled")
    func fillGateIsAtFourHundred() {
        #expect(DSStatusPill(statusCode: 200).isFilled == false)
        #expect(DSStatusPill(statusCode: 204).isFilled == false)
        #expect(DSStatusPill(statusCode: 302).isFilled == false)
        #expect(DSStatusPill(statusCode: 399).isFilled == false)
        #expect(DSStatusPill(statusCode: 400).isFilled)
        #expect(DSStatusPill(statusCode: 404).isFilled)
        #expect(DSStatusPill(statusCode: 500).isFilled)
        #expect(DSStatusPill(statusCode: 599).isFilled)
    }

    /// The label colour is `httpStatusColor(for:)`'s — the text variants, which are the tokens
    /// `DSContrastTests.statusPillTextClearsAAOnItsOwnFill` measures against this very fill.
    @Test("A coded pill takes its colour from httpStatusColor")
    func colourComesFromTheTokenFunction() {
        for code in [200, 302, 404, 500] {
            #expect(DSStatusPill(statusCode: code).color == DSColors.httpStatusColor(for: code))
        }
        #expect(DSStatusPill(statusCode: 200).text == "200")
    }

    /// The wash the contrast suite measures is the wash the component draws. `selfTintedReading`'s
    /// default alpha and this constant are one fact written twice; this is the line that notices
    /// them coming apart.
    @Test("The fill is the 12% self-tint the contrast suite measures")
    func fillOpacityIsPinned() {
        #expect(DSStatusPill.fillOpacity == 0.12)
    }

    /// The traffic header's chip: the count rides in the same pill, and the gate does not care.
    @Test("A detail suffix joins the code in one pill")
    func detailSuffix() {
        let chip = DSStatusPill(statusCode: 404, detail: "\u{00D7}3")
        #expect(chip.text == "404 \u{00D7}3")
        #expect(chip.color == DSColors.httpStatusColor(for: 404))
        #expect(chip.isFilled)
        #expect(DSStatusPill(statusCode: 200, detail: "\u{00D7}40").isFilled == false)
    }

    // MARK: - Geometry

    /// The same harness `DSComponentRenderingTests` hosts every component through, including the
    /// run-loop turn that lets `NSHostingController` settle before `fittingSize` is read.
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 200, height: 60),
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

    /// "Horizontal inset belongs to the fill; the vertical inset is paid on both so a row does not
    /// change height with its status code." Both halves, measured: a 500 and a 200 are the same
    /// three monospaced digits, so the width difference is exactly the fill's inset, and the
    /// heights must not differ at all — a row that grows when its endpoint starts failing is the
    /// regression this pins against.
    @Test("A filled pill is wider by its inset and no taller")
    func filledPillKeepsRowHeight() {
        let unfilled = render(DSStatusPill(statusCode: 200))
        let filled = render(DSStatusPill(statusCode: 500))
        #expect(filled.width > unfilled.width)
        #expect(filled.height == unfilled.height)

        // The failure arm shares that height too — the em dash sits in the same row slots.
        let failure = render(DSStatusPill(statusCode: nil))
        #expect(failure.height == unfilled.height)
    }
}
