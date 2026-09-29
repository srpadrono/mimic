import DesignSystem
import Domain
import SwiftUI

/// One step, as both a definition and a progress indicator.
///
/// The numbered node carries the run state by shape as well as colour: a tick when served, a ring
/// with a halo when current, a plain ring otherwise. The current row gets a tinted fill and an accent
/// border; the row the inspector shows gets a neutral fill.
struct JourneyStepRow: View {
    let step: JourneyStep
    let index: Int
    /// Run progress for this step, when a run is in flight.
    let progress: JourneyStepProgress?
    /// The step the inspector is showing.
    var isSelected = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            node
            DSMethodLabel(step.method.rawValue, fixedWidth: false, identifier: step.id.uuidString)
                .frame(width: 44, alignment: .leading)

            // The route alone, as the design draws it; the step's name is in the tooltip, the
            // spoken label and the inspector. It takes what the trailing facts leave, down to a floor.
            Text(routeLabel)
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(routeHelp)
                .frame(minWidth: Self.routeMinimumWidth, maxWidth: .infinity, alignment: .leading)

            trailingFacts
                .layoutPriority(1)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: DSRowHeight.step)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .fill(rowFill)
        }
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: DSCornerRadius.card)
                    .strokeBorder(DSColors.accent, lineWidth: DSStroke.emphasis)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
        .onHover { isHovered = $0 }
        // A served step recedes; its route and outcome stay legible.
        .opacity(isExhausted ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("journeyStep-\(index)")
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isCurrent: Bool { progress?.isCurrent == true }
    private var isExhausted: Bool { progress?.isExhausted == true }

    private var rowFill: Color {
        if isCurrent { return DSColors.selectionSoft }
        if isSelected { return DSColors.selectionInactive }
        return isHovered ? DSColors.hover : Color.clear
    }

    /// A name that only restates the route adds nothing to its tooltip.
    private var showsName: Bool {
        let name = step.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != step.path && name != routeLabel
    }

    private var routeLabel: String {
        guard let operation = step.graphqlOperation, !operation.isEmpty else { return step.path }
        return operation
    }

    private var routeHelp: String {
        var route = step.path
        if let operation = step.graphqlOperation, !operation.isEmpty { route = "\(operation) · \(step.path)" }
        return showsName ? "\(step.name) · \(route)" : route
    }

    // MARK: - Node

    /// One 22pt box whatever the state, so rows keep their height as a run moves through them.
    private var node: some View {
        ZStack {
            if isExhausted {
                Circle().fill(DSColors.success)
                Image(systemName: "checkmark")
                    .font(.system(size: DSGlyph.disclosure, weight: .bold))
                    .foregroundStyle(.white)
            } else if isCurrent {
                Circle()
                    .strokeBorder(DSColors.accent, lineWidth: 1.5)
                    .background(Circle().stroke(DSColors.selectionSoft, lineWidth: 6))
                Text("\(index + 1)")
                    .font(DSTypography.captionSemibold)
                    .monospacedDigit()
                    .foregroundStyle(DSColors.accent)
            } else {
                Circle().strokeBorder(DSColors.labelTertiary, lineWidth: 1.5)
                Text("\(index + 1)")
                    .font(DSTypography.captionSemibold)
                    .monospacedDigit()
                    .foregroundStyle(DSColors.labelSecondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    // MARK: - Trailing facts

    /// The narrowest the route gets before the trailing facts start to give way.
    private static let routeMinimumWidth: CGFloat = 64
    /// The run column, as wide as the design draws it, so every row's status sits in one column.
    private static let readoutWidth: CGFloat = 120

    /// Chips, status and the run readout, whole. As the pane narrows the readout's column tightens
    /// to its text, then the outcome chip goes, then the repeat chip; the status and the readout
    /// ("Served 1 of 1", "Waiting", "Not reached") always stay.
    private var trailingFacts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.md) {
                outcomeChip
                repeatChip
                statusLabel
                readout(width: Self.readoutWidth)
            }
            HStack(spacing: DSSpacing.md) {
                outcomeChip
                repeatChip
                statusLabel
                readout(width: nil)
            }
            HStack(spacing: DSSpacing.md) {
                repeatChip
                statusLabel
                readout(width: nil)
            }
            HStack(spacing: DSSpacing.md) {
                statusLabel
                readout(width: nil)
            }
        }
    }

    @ViewBuilder
    private var repeatChip: some View {
        if step.repeatCount > 1 { chip("\u{00D7} \(step.repeatCount)") }
    }

    /// What this step has done so far in the run, right-aligned in its column. Never truncated.
    @ViewBuilder
    private func readout(width: CGFloat?) -> some View {
        if let progress {
            Text(Self.progressText(progress))
                .font(DSTypography.Figure.regular)
                .foregroundStyle(progress.isCurrent ? DSColors.labelSecondary : DSColors.labelTertiary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: width, alignment: .trailing)
        }
    }

    // MARK: - Outcome

    /// What happens before, or instead of, a response: a delay, a dropped connection, a time-out.
    @ViewBuilder
    private var outcomeChip: some View {
        switch step.outcome {
        case .respond:
            if step.delayMs > 0 {
                chip("After \(Self.durationText(step.delayMs))", systemImage: "clock")
            }
        case let .networkFailure(failure):
            chip(Self.failureDisplayText(failure, delayMs: step.delayMs),
                 systemImage: failure == .connectionDrop ? "bolt.horizontal" : "hourglass")
                .help(Self.failureText(failure))
        }
    }

    /// Three monospaced digits at most (200–599), so it never needs to truncate.
    @ViewBuilder
    private var statusLabel: some View {
        if case let .respond(response) = step.outcome {
            DSStatusLabel(statusCode: response.statusCode)
        }
    }

    /// A quiet neutral fact about the step, shown whole or not at all (see `trailingFacts`).
    private func chip(_ text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: DSSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: DSGlyph.disclosure))
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(DSTypography.caption)
        .foregroundStyle(DSColors.labelSecondary)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.card).fill(DSColors.field)
        }
        .help(text)
    }

    // MARK: - Text

    /// The run column: what this step has done so far.
    static func progressText(_ progress: JourneyStepProgress) -> String {
        if progress.isExhausted || progress.servedCount > 0 {
            return "Served \(progress.servedCount) of \(progress.repeatCount)"
        }
        return progress.isCurrent ? "Waiting" : "Not reached"
    }

    /// Short prose for a transport failure, used by the step's spoken label and its tooltip.
    static func failureText(_ failure: NetworkFailure) -> String {
        switch failure {
        case .connectionDrop: "drop"
        case let .timeout(holdMs): "timeout \(holdMs)ms"
        }
    }

    /// The visible chip text for a transport failure: "Drop connection after 5 s".
    static func failureDisplayText(_ failure: NetworkFailure, delayMs: Int = 0) -> String {
        switch failure {
        case .connectionDrop:
            delayMs > 0 ? "Drop connection after \(durationText(delayMs))" : "Drop connection"
        case let .timeout(holdMs):
            "Time out after \(durationText(holdMs))"
        }
    }

    /// Whole seconds read as seconds ("5 s"); anything finer stays in milliseconds ("250 ms").
    static func durationText(_ milliseconds: Int) -> String {
        milliseconds >= 1000 && milliseconds % 1000 == 0
            ? "\(milliseconds / 1000) s"
            : "\(milliseconds) ms"
    }

    private var accessibilityDescription: String {
        var parts = ["Step \(index + 1)", step.name, step.method.rawValue, step.path]
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
/// Every optional trailing element at once, with long values.
private let widestStep = JourneyStep(
    name: "Poll stays pending",
    method: .post,
    path: "/account-summary/transactions",
    outcome: .networkFailure(.timeout(holdMs: 30_000)),
    delayMs: 270_000,
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
        failure: JourneyStepRow.failureText(.timeout(holdMs: 30_000)),
        repeatCount: step.repeatCount,
        servedCount: servedCount,
        isExhausted: false,
        isCurrent: true
    )
}

/// 300pt is roughly the narrowest centre pane. The node and method must start inside the row.
#Preview("Step row — 300pt") {
    VStack(spacing: 2) {
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
