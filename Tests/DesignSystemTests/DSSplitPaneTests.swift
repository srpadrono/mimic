import SwiftUI
import Testing
@testable import DesignSystem

@Suite("DSSplitPane sizing")
@MainActor
struct DSSplitPaneTests {
    private func pane(axis: Axis, isPresented: Bool) -> DSSplitPane<Text, Text> {
        DSSplitPane(
            axis: axis,
            isSecondaryPresented: .constant(isPresented),
            secondaryThickness: .constant(150),
            minimumPrimaryThickness: 120,
            minimumSecondaryThickness: 80,
            defaultSecondaryThickness: 150,
            identifier: "sizing"
        ) {
            Text("Primary")
        } secondary: {
            Text("Secondary")
        }
    }

    @Test("Visible panes reserve both minimums and the native divider")
    func visiblePanesIncludeDivider() {
        #expect(pane(axis: .vertical, isPresented: true).fittingSize(
            for: ProposedViewSize(width: 400, height: 150)
        ) == CGSize(width: 400, height: 210))
        #expect(pane(axis: .horizontal, isPresented: true).fittingSize(
            for: ProposedViewSize(width: 150, height: 400)
        ) == CGSize(width: 210, height: 400))
    }

    @Test("Hiding the secondary pane releases its minimum and divider")
    func collapsedPanesOnlyReservePrimary() {
        #expect(pane(axis: .vertical, isPresented: false).fittingSize(
            for: ProposedViewSize(width: 400, height: 150)
        ) == CGSize(width: 400, height: 150))
        #expect(pane(axis: .horizontal, isPresented: false).fittingSize(
            for: ProposedViewSize(width: 150, height: 400)
        ) == CGSize(width: 150, height: 400))
        #expect(pane(axis: .vertical, isPresented: false).fittingSize(
            for: ProposedViewSize(width: 400, height: 50)
        ) == CGSize(width: 400, height: 120))
        #expect(pane(axis: .horizontal, isPresented: false).fittingSize(
            for: ProposedViewSize(width: 50, height: 400)
        ) == CGSize(width: 120, height: 400))
    }

    @Test("Unspecified and unbounded proposals use the split axis")
    func unboundedProposalsUseAxis() {
        for proposal in [ProposedViewSize.unspecified, ProposedViewSize(width: .infinity, height: .infinity)] {
            #expect(pane(axis: .vertical, isPresented: true).fittingSize(for: proposal)
                    == CGSize(width: 120, height: 210))
            #expect(pane(axis: .horizontal, isPresented: true).fittingSize(for: proposal)
                    == CGSize(width: 210, height: 120))
            #expect(pane(axis: .vertical, isPresented: false).fittingSize(for: proposal)
                    == CGSize(width: 120, height: 120))
            #expect(pane(axis: .horizontal, isPresented: false).fittingSize(for: proposal)
                    == CGSize(width: 120, height: 120))
        }
    }

    @Test("A larger concrete proposal is accepted without expanding the split")
    func concreteProposalIsPreserved() {
        let proposal = ProposedViewSize(width: 700, height: 500)
        for axis in [Axis.vertical, .horizontal] {
            #expect(pane(axis: axis, isPresented: true).fittingSize(for: proposal)
                    == CGSize(width: 700, height: 500))
            #expect(pane(axis: axis, isPresented: false).fittingSize(for: proposal)
                    == CGSize(width: 700, height: 500))
        }
    }
}
