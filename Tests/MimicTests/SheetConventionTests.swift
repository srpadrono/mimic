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

    /// Both sheets open at one width, which is the part of "the shared sheet convention" that is a
    /// number.
    ///
    /// Both views size themselves from `DSSheetWidth.compact`, one as a fixed width and one as a
    /// minimum and ideal width. Compared with each other first, so it is the agreement being asserted
    /// and either sheet leaving it fails here, then against the compact sheet's 440pt floor.
    @Test("The two creation sheets open at one width")
    func creationSheetsShareOneWidth() {
        let endpointSheet = render(NewEndpointSheet(existingGroups: ["Account", "Catalog"]) { _ in })
        let projectSheet = render(NewProjectSheet { _, _ in })

        #expect(endpointSheet.width == projectSheet.width)
        // And it is the stated floor, not whatever the fields happened to measure.
        #expect(endpointSheet.width >= 440)
    }
}
