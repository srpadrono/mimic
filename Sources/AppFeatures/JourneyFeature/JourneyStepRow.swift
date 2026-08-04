import DesignSystem
import Domain
import SwiftUI

/// One step, as both a definition and a progress indicator.
///
/// The leading marker is the run state (▶ current, ✓ exhausted) and the trailing text is what the
/// step does. Reading down the column tells you where the flow is without a second panel.
///
/// Three things carry "this is the step the run is on", because one of them is never enough: the
/// glyph (a shape, not a colour), the accent on the number, and the weight of the path. Colour alone
/// would leave the marker invisible to a third of the people reading it, and the marker is the whole
/// reason the run is shown in the list you edit.
struct JourneyStepRow: View {
    let step: JourneyStep
    let index: Int
    /// Run progress for this step, when a run is in flight.
    let progress: JourneyStepProgress?

    /// The method column. Sized for `OPTIONS`, the widest method there is — the previous 58pt was
    /// sized for `DELETE` and let the longest badge spill over the path beside it. Matches the
    /// request log's method column, so the two lists line up when both are on screen.
    private static let methodColumnWidth: CGFloat = 62

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            marker
                .frame(width: 16)

            Text("\(index + 1)")
                .font(DSTypography.caption)
                .fontWeight(isCurrent ? .semibold : .medium)
                .foregroundStyle(isCurrent ? DSColors.accentText : DSColors.labelSecondary)
                .lineLimit(1)
                // `minWidth`, not `width`: the column aligns at one and two digits and simply grows
                // at three, rather than clipping a journey with a hundred steps in it.
                .frame(minWidth: 18, alignment: .trailing)

            DSMethodBadge(method: step.method.rawValue, size: .compact, identifier: step.id.uuidString)
                .frame(width: Self.methodColumnWidth, alignment: .leading)

            // A GraphQL route repeats for every operation, so the operation is the informative part.
            //
            // This column takes the slack the fixed ones leave, which is what makes the row survive
            // centre-pane width: everything trailing it is short and rigid, so the path is the only
            // thing that ever has to give up characters, and it truncates in the middle where a path
            // can most afford it.
            VStack(alignment: .leading, spacing: 0) {
                Text(step.path)
                    .font(DSTypography.code)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let operation = step.graphqlOperation, !operation.isEmpty {
                    Text(operation)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.accentText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            outcomeLabel

            if step.delayMs > 0 {
                annotation("+\(step.delayMs)ms")
            }
            if step.repeatCount > 1 {
                annotation(servedAnnotation)
            }
        }
        .padding(.vertical, DSSpacing.xs)
        // The row opens the step editor on tap, so it says so on hover like every other tappable
        // row — the sidebar's, the journeys navigator's, the scenario list's. It was the one
        // clickable row in the app with no pointer feedback at all.
        .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
        // Enough to read as spent, not so much that a served step becomes unreadable — at 0.55 the
        // tick and the number underneath it landed around 20% alpha, which is a row you can see the
        // shape of and not the content of.
        .opacity(isExhausted ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("journeyStep-\(index)")
        .accessibilityLabel(accessibilityDescription)
    }

    private var isCurrent: Bool { progress?.isCurrent == true }
    private var isExhausted: Bool { progress?.isExhausted == true }

    @ViewBuilder
    private var marker: some View {
        Group {
            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DSColors.accentText)
            } else if isExhausted {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DSColors.labelSecondary)
            } else {
                Color.clear
            }
        }
        // One box whatever the state, so rows do not change height as a run moves through them.
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var outcomeLabel: some View {
        switch step.outcome {
        case let .respond(response):
            // Coloured text, and a fill once the code is one you would stop on — the same `>= 400`
            // seam the request log and the endpoint traffic list use. The old note here argued
            // against "a badge that is always on", which is right, but that is exactly what the
            // conditional prevents: withholding the fill at 500 too meant a failing step was the one
            // row in the app where a failure did *not* announce itself.
            Text("\(response.statusCode)")
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.httpStatusColor(for: response.statusCode))
                .lineLimit(1)
                .padding(.horizontal, response.statusCode >= 400 ? DSSpacing.xs : 0)
                .padding(.vertical, 1)
                .background {
                    if response.statusCode >= 400 {
                        RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                            .fill(DSColors.httpStatusColor(for: response.statusCode).opacity(0.12))
                    }
                }
                // The one `.fixedSize()` left in this row, and the only one that is bounded:
                // `EndpointValidator.serveableStatusCodes` runs 200–599, so this is three
                // monospaced digits — 20.4pt — whatever the step does. It cannot be the thing that
                // overflows the row, and a status code truncated to "5…" would be worse than useless.
                .fixedSize()
        case let .networkFailure(failure):
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: failure == .connectionDrop ? "bolt.horizontal.circle" : "clock.badge.exclamationmark")
                    .font(.system(size: 10))
                Text(Self.failureText(failure))
                    .font(DSTypography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(DSColors.labelSecondary)
            // No `.fixedSize()`. The note that used to sit here said it was what stopped
            // "timeout 30000ms" wrapping to a second line and doubling the row's height — but
            // `.lineLimit(1)` above is what does that. What `.fixedSize()` actually did was forbid
            // *truncation*, and this string is unbounded: the hold is any number of milliseconds a
            // user types, so "timeout 3600000ms" measures 101pt against "drop"'s 23.
            //
            // Rendered at 300pt — the centre pane with both drawers open — the rigid version pushed
            // the row's leading edge clean out of its own bounds: the run marker drew outside the
            // row and the path column collapsed to nothing. That is the `DSPanelHeader` "narios"
            // defect exactly. The tooltip carries the full string for the narrow case.
            .help(Self.failureText(failure))
        }
    }

    /// A quiet trailing fact about the step — the extra delay it adds, or how far through its repeat
    /// count the run is.
    ///
    /// Text, not a capsule. Two neutral pills and a coloured one on every row read as three controls
    /// you could press, and none of them is.
    ///
    /// Quiet also means first to yield. Both strings are unbounded — the delay is whatever
    /// millisecond count was typed, the served ratio whatever the repeat count is — so "+3600000ms"
    /// and "1000/1000" together claim 120pt of a row that has 300 to spend at centre-pane width.
    /// With `.fixedSize()` here they took it, and the marker, the number and the path were the ones
    /// that gave way instead. Priority in this row runs the other way round: the marker is the whole
    /// reason a run is shown in the list you edit.
    @ViewBuilder
    private func annotation(_ text: String) -> some View {
        Text(text)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.labelSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }

    private var servedAnnotation: String {
        guard let progress else { return "\u{00D7}\(step.repeatCount)" }
        return "\(progress.servedCount)/\(step.repeatCount)"
    }

    static func failureText(_ failure: NetworkFailure) -> String {
        switch failure {
        case .connectionDrop: "drop"
        case let .timeout(holdMs): "timeout \(holdMs)ms"
        }
    }

    private var accessibilityDescription: String {
        var parts = ["Step \(index + 1)", step.method.rawValue, step.path]
        if let operation = step.graphqlOperation, !operation.isEmpty {
            parts.append("operation \(operation)")
        }
        switch step.outcome {
        case let .respond(response): parts.append("responds \(response.statusCode)")
        case let .networkFailure(failure): parts.append("fails with \(Self.failureText(failure))")
        }
        if step.repeatCount > 1 { parts.append("repeats \(step.repeatCount) times") }
        if isCurrent { parts.append("current step") }
        if isExhausted { parts.append("already served") }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
/// The worst row this list can hold: a timeout, a delay and a repeat count all at once, so every
/// optional trailing element is present and every unbounded string is long.
private let widestStep = JourneyStep(
    name: "Poll stays pending",
    method: .post,
    path: "/account-summary/transactions",
    outcome: .networkFailure(.timeout(holdMs: 3_600_000)),
    delayMs: 3_600_000,
    repeatCount: 100
)

private func progress(for step: JourneyStep, servedCount: Int) -> JourneyStepProgress {
    JourneyStepProgress(
        id: step.id,
        index: 0,
        name: step.name,
        method: step.method,
        path: step.path,
        statusCode: nil,
        failure: JourneyStepRow.failureText(.timeout(holdMs: 3_600_000)),
        repeatCount: step.repeatCount,
        servedCount: servedCount,
        isExhausted: false,
        isCurrent: true
    )
}

/// Both widths, for the reason `JourneyRunControls` keeps two previews: the row is only correct at
/// one of them by accident. 300pt is roughly as narrow as the centre pane goes with both drawers
/// open, and it is where the trailing elements used to shove the marker off the leading edge.
///
/// **What to look at is where the ink starts.** The marker, the step number and the method badge
/// must all begin inside the row; if the play glyph is clipped or missing, something in the row has
/// gone rigid again.
#Preview("Step row — 300pt") {
    VStack(spacing: 0) {
        JourneyStepRow(step: widestStep, index: 11, progress: progress(for: widestStep, servedCount: 42))
        JourneyStepRow(
            step: JourneyStep(name: "Recovers", path: "/account-summary", outcome: .respond(JourneyResponse(statusCode: 200))),
            index: 12,
            progress: nil
        )
    }
    .padding(.horizontal, DSSpacing.sm)
    .frame(width: 300)
}

#Preview("Step row — wide") {
    JourneyStepRow(step: widestStep, index: 11, progress: progress(for: widestStep, servedCount: 42))
        .padding(.horizontal, DSSpacing.sm)
        .frame(width: 640)
}
#endif
