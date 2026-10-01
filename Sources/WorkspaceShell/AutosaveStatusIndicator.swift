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
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.8)
                            .frame(width: 10, height: 10)
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
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: DSGlyph.disclosure, weight: .semibold))
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
