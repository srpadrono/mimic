import SwiftUI
import Domain
import DesignSystem

/// The toolbar's statement that endpoints are not currently in charge.
///
/// An active journey overrides every endpoint in the project, which makes it the one piece of state
/// that changes what *every other control in the window* means — and until now the toolbar said
/// nothing about it. You could be editing an endpoint's response while a journey answered that route
/// with something else entirely.
struct DSJourneyChip: View {
    let status: JourneyStatus

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))

            Text(status.journeyName)
                .font(DSTypography.metaBold)
                // The one string here that can grow. No `.fixedSize()`: this sits in a toolbar beside
                // the server segment, and a fixed-size label makes the row demand more width than the
                // bar has.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 140, alignment: .leading)

            DSProgressSegments(states: segmentStates, identifier: "journeyChip.progress")
                .frame(width: 36)

            Text("\(status.totalServed)/\(status.totalSteps)")
                .font(DSTypography.Figure.small)
        }
        .foregroundStyle(DSColors.accentText)
        .padding(.horizontal, DSSpacing.sm)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.lg)
                .fill(DSColors.accent.opacity(0.11))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.lg)
                .stroke(DSColors.accent.opacity(0.38), lineWidth: 0.5)
        }
        .help("\(status.journeyName) is answering — \(status.totalServed) of \(status.totalSteps) steps served")
        .accessibilityIdentifier("toolbar.journeyChip")
        .accessibilityLabel(
            "Journey \(status.journeyName) active, \(status.totalServed) of \(status.totalSteps) steps served"
        )
    }

    /// Read from each step's own `isExhausted`, never from the cursor index.
    ///
    /// Under `orderedPerEndpoint` the resolver scans forward, so step 4 can be exhausted while the
    /// cursor sits on step 2 — the design's "filled up to the cursor" would draw one segment of four
    /// with three served.
    private var segmentStates: [Bool] {
        status.steps.map(\.isExhausted)
    }
}
