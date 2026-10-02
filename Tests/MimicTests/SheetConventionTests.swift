import AppKit
import SwiftUI
import Testing
@testable import EndpointsFeature
@testable import ProjectsFeature

/// Conventions two sections share, checked where both are in reach.
@Suite("Sheet conventions")
@MainActor
struct SheetConventionTests {
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 1000, height: 800),
        wait: TimeInterval = 0.05
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
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    /// Each creation sheet opens at the width its artboard draws: the two-field new project sheet
    /// at `DSSheetWidth.short`, the new endpoint sheet at `DSSheetWidth.endpoint`.
    ///
    /// Both are fixed widths, so each must be exactly the design's.
    @Test("The creation sheets open at their design widths")
    func creationSheetsOpenAtTheirDesignWidths() {
        let endpointSheet = render(NewEndpointSheet(existingGroups: ["Account", "Catalog"]) { _ in })
        let projectSheet = render(NewProjectSheet { _, _ in })

        #expect(projectSheet.width == 377)
        #expect(endpointSheet.width == 407)
    }
}
