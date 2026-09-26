import DesignSystem
import Domain
import SwiftUI

/// Names a journey captured from traffic the server has already answered.
///
/// Presented for a single request or for a whole selection, which is why it says what it is about to
/// build before it builds it. Eight selected calls can be five steps once repeated polls collapse and
/// requests an active journey already answered drop out; discovering that only afterwards, in the
/// editor, makes a correct capture look like a bug.
///
/// Follows the shared sheet convention: a sentence-case heading inside the sheet, `DSSpacing.lg`
/// between the heading, the fields and the button row, `DSSpacing.lg` of outer padding, and a
/// trailing button row with cancel to the left of the confirm action.
struct CaptureJourneySheet: View {
    @Environment(\.dismiss) private var dismiss

    /// What the sheet was opened for.
    ///
    /// Identifiable so the sheet is presented with `sheet(item:)`: the pending selection *is* the
    /// "is the sheet up" state, and keeping a separate boolean beside it would be two sources of
    /// truth that can disagree.
    struct Capture: Identifiable {
        let id = UUID()
        /// The requests to capture, in whatever order the table handed them over. Ordering into a
        /// flow is `JourneyStepSpec.capturing(_:)`'s job, not this sheet's.
        let logs: [RequestLog]
        let suggestedName: String
        /// How many steps the capture will actually produce, which is not `logs.count`.
        let stepCount: Int
        let refusal: String?

        init(logs: [RequestLog], suggestedName: String) {
            self.logs = logs
            self.suggestedName = suggestedName
            let preview = JourneyCapture.preview(logs)
            stepCount = preview.stepCount
            refusal = preview.refusal
        }

        var summary: String {
            if let refusal { return refusal }
            if logs.count == 1 {
                return "Captures this request as one step, reproducing the response it received."
            }
            let eligible = logs.filter { $0.outcome != .journey }.count
            var text = "Captures \(eligible) requests in the order they arrived, as \(stepCount) \(stepCount == 1 ? "step" : "steps")."
            if eligible < logs.count {
                text += " Requests already answered by a journey are excluded."
            }
            if stepCount < eligible {
                text += " Consecutive identical responses become one step that repeats."
            }
            return text
        }
    }

    let capture: Capture
    let onCreate: (String, [RequestLog]) -> Void

    private enum Field: Hashable {
        case name
    }

    @State private var name: String
    @FocusState private var focusedField: Field?

    init(capture: Capture, onCreate: @escaping (String, [RequestLog]) -> Void) {
        self.capture = capture
        self.onCreate = onCreate
        _name = State(initialValue: capture.suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("New journey from traffic")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)

                Text(capture.summary)
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("captureJourney.summary")
            }

            DSTextField(
                "Name",
                text: $name,
                placeholder: "e.g. Checkout retries",
                identifier: "captureJourney.name"
            )
            .accessibilityIdentifier("captureJourney.nameField")
            .focused($focusedField, equals: .name)
            .onSubmit(create)

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "captureJourney.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("captureJourney.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Create journey",
                    variant: .primary,
                    size: .medium,
                    identifier: "captureJourney.create",
                    action: create
                )
                .accessibilityIdentifier("captureJourney.createButton")
                .accessibilityLabel("Create journey")
                .disabled(trimmedName.isEmpty || capture.refusal != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .defaultFocus($focusedField, .name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty, capture.refusal == nil else { return }
        onCreate(trimmedName, capture.logs)
        dismiss()
    }
}
