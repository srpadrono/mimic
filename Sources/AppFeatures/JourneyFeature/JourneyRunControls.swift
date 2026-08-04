import DesignSystem
import Domain
import SwiftUI

/// Activate, rewind, and step a journey while it is serving.
///
/// These are the controls a test driver needs between cases: activate the flow, run it, rewind. They
/// sit above the step list because they act on the run, not on the definition.
///
/// **The row assumes no particular width.** It renders in the journeys window's detail pane and in
/// the main window's centre pane, which a user can drag down to around 300pt. Nothing here is given a
/// fixed size: while the controls and the readout fit on one line the readout holds the trailing
/// edge, and when they stop fitting it drops underneath them rather than being crushed into an
/// ellipsis or pushing the buttons off the leading edge.
struct JourneyRunControls: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.sm) {
                runButtons

                // `Spacer()` would report an ideal width of zero, so this candidate would always
                // claim to fit and the stacked one below would never be chosen — `ViewThatFits`
                // measures ideal sizes, and a flexible spacer's ideal size is nothing. `minLength`
                // is what makes the measurement honest.
                Spacer(minLength: DSSpacing.md)

                progressReadout
            }

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.sm) {
                    runButtons
                    Spacer(minLength: 0)
                }

                progressReadout
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        // The control-row rung, and the row now lands on it exactly: `DSButton(.small)` is a pinned
        // 20pt, so `DSSpacing.sm` above and below makes 32. It stood at 33 while these were bordered
        // system buttons — AppKit draws a small one at 21 where a small popup or segmented control
        // measures 20 — and that one-point drift is the smaller half of why they are `DSButton`s now:
        // a row's height should not depend on which kind of control somebody reached for.
        //
        // A floor rather than a fixed height, because of the `ViewThatFits` above. The stacked
        // candidate is two rows and needs about 52; pinning the frame would hold it at one row's worth
        // of space and let it draw over whatever is underneath.
        .frame(minHeight: DSBarHeight.controlRow)
    }

    // MARK: - Controls

    /// One set of buttons, laid out by whichever candidate above wins.
    ///
    /// `DSButton`, like every other worded action in the window. These four were bordered system
    /// buttons at `.controlSize(.small)`, rendering directly below a header whose own button had
    /// already been moved across — and whose comment claimed it had been "the only bordered system
    /// button in any header", with these four sitting a few lines underneath it in the same file. A
    /// system button draws AppKit's shape at ≈19pt beside the 20pt siblings elsewhere and takes the
    /// system accent rather than `DSColors.accent`.
    ///
    /// **The glyphs went with them, and nothing was lost.** `DSButton` is worded-only, which is the
    /// house idiom for a bar — "Add step" above this row carries no glyph either, nor do the import
    /// review's header actions. "Activate", "Restart" and "Advance" are words that say what they do;
    /// the icons stay where they are load-bearing, on the navigator's activation ring and in the
    /// context menus, where there is no room for a word.
    ///
    /// **They are not all the same weight.** Activating is what you came to this row to do, so it is
    /// the one slab. The other three act on a run that is already going and are recessed wells.
    @ViewBuilder
    private var runButtons: some View {
        if isActive {
            // Secondary, not destructive. Deactivating is the consequential one — it stops a journey
            // answering for every endpoint in the project — but a red button in a control row you sit
            // beside for a whole testing session reads as an error rather than as the way out. The
            // tooltip carries the consequence instead.
            DSButton(
                "Deactivate",
                variant: .secondary,
                size: .small,
                identifier: "journeyRun.deactivate"
            ) {
                appState.activateJourney(id: nil)
            }
            .help("Stop the journey. Endpoints answer for themselves again.")
            .accessibilityIdentifier("journeyRun.deactivateButton")
            .accessibilityLabel("Deactivate journey")
        } else {
            DSButton(
                "Activate",
                variant: .primary,
                size: .small,
                identifier: "journeyRun.activate"
            ) {
                appState.activateJourney(id: journey.id)
            }
            .disabled(journey.steps.isEmpty)
            .help("Serve this journey's steps instead of the endpoints' own responses.")
            .accessibilityIdentifier("journeyRun.activateButton")
            .accessibilityLabel("Activate journey")
        }

        DSButton(
            "Restart",
            variant: .secondary,
            size: .small,
            identifier: "journeyRun.restart"
        ) {
            appState.restartActiveJourney()
        }
        .disabled(!isActive)
        .help("Rewind the run to the first step.")
        .accessibilityIdentifier("journeyRun.restartButton")
        .accessibilityLabel("Restart journey")

        DSButton(
            "Advance",
            variant: .secondary,
            size: .small,
            identifier: "journeyRun.advance"
        ) {
            appState.advanceActiveJourney()
        }
        .disabled(!isActive || status?.isComplete == true)
        .help("Retire the current step without serving it.")
        .accessibilityIdentifier("journeyRun.advanceButton")
        .accessibilityLabel("Advance journey")
    }

    // MARK: - Readout

    /// Where the run has got to — or, when nothing is running, that nothing is.
    private var progressReadout: some View {
        Text(progressText)
            .font(DSTypography.label)
            // Never `labelTertiary`. This line answers "is something overriding my endpoints right
            // now", which is the first thing you check when a response surprises you, and 36% alpha
            // is not where you put an answer somebody has to read.
            .foregroundStyle(isActive ? DSColors.labelPrimary : DSColors.labelSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            // The stacked layout gives this line the full width, so it truncates only in the gap
            // between the two candidates. The tooltip covers that gap.
            .help(progressText)
            .accessibilityIdentifier("journeyRun.progress")
    }

    private var progressText: String {
        guard isActive else { return "Not active — endpoints answer directly" }
        guard let status else { return "Not started" }
        if status.isComplete {
            return "Complete — \(status.totalServed) served"
        }
        guard let index = status.currentStepIndex else {
            return "\(status.totalServed) served"
        }
        return "Step \(index + 1) of \(status.totalSteps) — \(status.totalServed) served"
    }
}

#if DEBUG
/// Both widths, because the single-row layout is only correct at one of them. 300pt is roughly as
/// narrow as the centre pane goes with both side panels open.
#Preview("Run controls — wide") {
    let journey = Journey(
        name: "Retry after failure",
        steps: [
            JourneyStep(name: "Fails", path: "/account", outcome: .respond(JourneyResponse(statusCode: 500))),
            JourneyStep(name: "Recovers", path: "/account", outcome: .respond(JourneyResponse(statusCode: 200)))
        ]
    )

    JourneyRunControls(
        journey: journey,
        isActive: true,
        status: JourneyStatus.make(journey: journey, state: nil)
    )
    .environment(AppState.preview())
    .frame(width: 640)
}

#Preview("Run controls — 300pt") {
    JourneyRunControls(journey: Journey(name: "Scratch flow"), isActive: false, status: nil)
        .environment(AppState.preview())
        .frame(width: 300)
}
#endif
