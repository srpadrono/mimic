import DesignSystem
import Domain
import SwiftUI

/// Appends steps to a journey from requests the server has already answered.
///
/// The editor's "Capture from log" opens this. The journey screen does not show the request log, so
/// the requests are listed here, newest first, and the checked ones become steps in the order they
/// arrived — the same rule the log's "Add to journey" applies to a selection.
struct CaptureFromLogSheet: View {
    @Environment(\.dismiss) private var dismiss

    let journeyName: String
    let logs: [RequestLog]
    let onCapture: ([RequestLog]) -> Void

    @State private var checked: Set<UUID> = []

    /// Enough to find the calls of one flow without a list that scrolls forever.
    static let listLimit = 50

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Capture from log")
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("captureFromLog.title")
                Text(summary)
                    .font(DSTypography.callout)
                    .foregroundStyle(refusal == nil ? DSColors.labelSecondary : DSColors.error)
                    .lineSpacing(DSTypography.Leading.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("captureFromLog.summary")
            }

            if recentLogs.isEmpty {
                DSEmptyState(
                    heading: "No requests yet",
                    message: "Requests the server answers appear here. Run your app against Mimic, then capture them.",
                    prominence: .compact,
                    identifier: "captureFromLog.empty"
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: DSSpacing.xxs) {
                        ForEach(recentLogs) { log in
                            row(log)
                        }
                    }
                    .padding(DSSpacing.xs)
                }
                .frame(height: 260)
                .background {
                    RoundedRectangle(cornerRadius: DSCornerRadius.card).fill(DSColors.code)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.card)
                        .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("captureFromLog.list")
            }

            HStack(spacing: DSSpacing.sm) {
                Spacer()
                DSButton("Cancel", variant: .secondary, size: .large, identifier: "captureFromLog.cancel",
                         action: dismiss.callAsFunction)
                    .accessibilityIdentifier("captureFromLog.cancelButton")
                    .accessibilityLabel("Cancel")
                    .keyboardShortcut(.cancelAction)
                DSButton(addTitle, variant: .primary, size: .large, identifier: "captureFromLog.add",
                         action: capture)
                    .accessibilityIdentifier("captureFromLog.addButton")
                    .accessibilityLabel(addTitle)
                    .disabled(selection.isEmpty || refusal != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.xl)
        .frame(width: DSSheetWidth.medium)
        .background(DSColors.sheet)
        .dsSheetSurface()
    }

    private func row(_ log: RequestLog) -> some View {
        let isChecked = checked.contains(log.id)
        return Button {
            if isChecked { checked.remove(log.id) } else { checked.insert(log.id) }
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: DSGlyph.button))
                    .foregroundStyle(isChecked ? DSColors.accent : DSColors.labelTertiary)
                    .accessibilityHidden(true)
                Text(log.timestamp, format: .dateTime.hour().minute().second())
                    .font(DSTypography.Figure.regular)
                    .foregroundStyle(DSColors.labelSecondary)
                DSMethodLabel(log.method.rawValue, fixedWidth: false, identifier: "captureFromLog.\(log.id.uuidString)")
                    .frame(width: 52, alignment: .leading)
                Text(log.path)
                    .font(DSTypography.code)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DSStatusLabel(statusCode: log.responseStatusCode, reason: log.responseStatusCode == nil ? log.failureLabel : nil)
            }
            .padding(.horizontal, DSSpacing.sm)
            .frame(height: DSRowHeight.list)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.field)
                    .fill(isChecked ? DSColors.selectionSoft : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(log.method.rawValue) \(log.path)")
        .accessibilityValue(isChecked ? "Selected" : "Not selected")
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("captureFromLog.row.\(log.path)")
    }

    /// Newest first, and only requests a journey did not already answer: those would add nothing.
    private var recentLogs: [RequestLog] {
        Array(
            logs.filter { $0.outcome != .journey }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(Self.listLimit)
        )
    }

    private var selection: [RequestLog] {
        logs.filter { checked.contains($0.id) }
    }

    private var preview: JourneyCapture.Preview? {
        selection.isEmpty ? nil : JourneyCapture.preview(selection)
    }

    private var refusal: String? { preview?.refusal }

    private var summary: String {
        if let refusal { return refusal }
        return "Checked requests become steps at the end of \u{201C}\(journeyName)\u{201D}, in the order they arrived."
    }

    private var addTitle: String {
        guard let count = preview?.stepCount, count > 0 else { return "Add steps" }
        return count == 1 ? "Add 1 step" : "Add \(count) steps"
    }

    private func capture() {
        guard !selection.isEmpty, refusal == nil else { return }
        onCapture(selection)
        dismiss()
    }
}
