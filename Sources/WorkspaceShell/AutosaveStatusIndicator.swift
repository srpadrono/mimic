import SwiftUI
import Domain
import DesignSystem

/// Autosave state, shown quietly at the end of the jump bar.
public struct AutosaveStatusIndicator: View {
    let status: AutosaveStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: AutosaveStatus) {
        self.status = status
    }

    public var body: some View {
        Group {
            switch status {
            case .idle:
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            case .saving:
                accessibleStatusView(identifier: "autosaveStatus.saving", label: "Saving") {
                    HStack(spacing: 5) {
                        AutosaveSpinner()
                        Text("Saving\u{2026}")
                            .foregroundStyle(DSColors.labelSecondary)
                    }
                }
            case .saved:
                accessibleStatusView(identifier: "autosaveStatus.saved", label: "All changes saved") {
                    Text("Saved")
                        .foregroundStyle(DSColors.labelTertiary)
                }
            case .failed(let message):
                accessibleStatusView(identifier: "autosaveStatus.failed", label: "Could not save changes") {
                    HStack(spacing: 5) {
                        // An outline, as the design draws it: the colour and the words carry the alarm.
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: DSGlyph.field, weight: .regular))
                        Text("Not saved")
                    }
                    .foregroundStyle(DSColors.error)
                    .help(message)
                }
            }
        }
        .font(DSTypography.caption)
        .animation(reduceMotion ? nil : .easeOut(duration: DSAnimation.fast), value: status)
    }

    private func accessibleStatusView<Content: View>(
        identifier: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }
}

/// The design's 10pt saving ring: a quiet track with an accent arc over the top, turning while a
/// save is in flight. A drawn ring rather than the system spinner, which is twice the weight at this
/// size. With Reduce Motion on it holds still; the word beside it says what is happening.
struct AutosaveSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTurning = false

    static let diameter: CGFloat = 10
    static let lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(DSColors.labelTertiary, lineWidth: Self.lineWidth)
            // A quarter of the ring, centred on twelve o'clock: the trim starts at three o'clock.
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(DSColors.accent, lineWidth: Self.lineWidth)
                .rotationEffect(.degrees(-135))
        }
        .padding(Self.lineWidth / 2)
        .frame(width: Self.diameter, height: Self.diameter)
        .rotationEffect(.degrees(isTurning ? 360 : 0))
        .animation(isTurning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : nil, value: isTurning)
        .onAppear { isTurning = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in isTurning = !reduced }
        .accessibilityHidden(true)
    }
}
