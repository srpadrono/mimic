import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("DesignSystem checkbox", .serialized)
@MainActor
struct DSCheckboxTests {
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        controller.view.layoutSubtreeIfNeeded()
        return controller.view.fittingSize
    }

    /// The table checkbox is the design's 14 pt box in every state, so a row never shifts as it changes.
    @Test("The checkbox is 14 by 14, off, on or mixed")
    func checkboxKeepsTheDesignSize() {
        for mark in [DSCheckboxBox.Mark.off, .on, .mixed] {
            #expect(fittingSize(DSCheckboxBox(mark: mark)) == CGSize(width: 14, height: 14), "\(mark)")
        }
    }

    @Test("A checkbox toggle draws the box alone, its label kept for VoiceOver")
    func labelsHiddenToggleIsTheBox() {
        let toggle = Toggle("Import GET /products", isOn: .constant(true))
            .toggleStyle(.dsCheckbox)
            .labelsHidden()
        #expect(fittingSize(toggle) == CGSize(width: 14, height: 14))
    }
}
