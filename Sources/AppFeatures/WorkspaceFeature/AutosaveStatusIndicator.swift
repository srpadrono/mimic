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
                        // `labelSecondary`, like "Saved" below. These two words are the whole of the
                        // app's answer to "did my edit land?", and `DSContrastTests` asserts that
                        // `labelTertiary` clears AA on no surface here, in either appearance. The
                        // failure case beside them was already legible; the two that report success
                        // were not.
                        .foregroundStyle(DSColors.labelSecondary)
                }
            case .saved:
                accessibleStatusView(identifier: "autosaveStatus.saved", label: "All changes saved") {
                    HStack(spacing: DSSpacing.xxs) {
                        Image(systemName: "checkmark")
                            // `indicator`, the bottom of `DSGlyph`'s ladder and the rung it names
                            // this mark for: it annotates the word beside it and never speaks alone.
                            .font(.system(size: DSGlyph.indicator, weight: .medium))
                            .foregroundStyle(DSColors.success)
                        Text("Saved")
                            .font(DSTypography.caption)
                            // See "Saving…" above.
                            .foregroundStyle(DSColors.labelSecondary)
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
