import SwiftUI
import Domain
import DesignSystem

/// Compact autosave status text — idle/saving/saved/failed.
struct AutosaveStatusIndicator: View {
    let status: AutosaveStatus

    public init(status: AutosaveStatus) {
        self.status = status
    }

    public var body: some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .saving:
                accessibleStatusView(identifier: "autosaveStatus.saving", label: "Saving") {
                    Text("Saving\u{2026}")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelTertiary)
                }
            case .saved:
                accessibleStatusView(identifier: "autosaveStatus.saved", label: "All changes saved") {
                    HStack(spacing: DSSpacing.xxs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(DSColors.success)
                        Text("Saved")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.labelTertiary)
                    }
                }
            case .failed(let message):
                accessibleStatusView(identifier: "autosaveStatus.failed", label: "Could not save changes") {
                    Text("Save failed")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.destructive)
                        .help(message)
                }
            }
        }
        .animation(.easeOut(duration: DSAnimation.fast), value: status)
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
