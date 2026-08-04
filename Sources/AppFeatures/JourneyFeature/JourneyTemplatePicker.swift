import DesignSystem
import Domain
import SwiftUI

/// Picks a journey off the built-in shelf.
///
/// The templates cover the scenarios teams reproduce most often, and each is also a worked example of
/// the step vocabulary — so starting here is faster *and* teaches the shape of a journey.
struct JourneyTemplatePicker: View {
    @Environment(\.dismiss) private var dismiss

    /// `(templateID, activateImmediately)`
    let onAdd: (String, Bool) -> Void

    @State private var selection: String = JourneyTemplates.all.first?.id ?? ""
    @State private var activate = true

    var body: some View {
        // `lg`, like every other sheet's root stack. This was the only one at `md`.
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Add a journey from a template")
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

            List(JourneyTemplates.all, selection: $selection) { template in
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(template.title)
                        .font(DSTypography.body)
                        .foregroundStyle(DSColors.labelPrimary)

                    // `.fixedSize(horizontal: false, vertical: true)` is safe *here*: a `List` row is
                    // proposed a bounded width and an unbounded height, and nothing in this row's
                    // ancestry claims `.frame(maxHeight: .infinity)`, so this asks the summary to
                    // wrap rather than truncate and nothing more. It is the same modifier that made
                    // `DSEmptyState` claim a thousand points of height, and the difference is only
                    // ever the container.
                    Text(template.summary)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // `labelSecondary`, not `labelTertiary`. 36% alpha is right for a timestamp you
                    // glance past and wrong for the one number that says how much journey a template
                    // is — the same correction the journeys list and the journeys navigator already
                    // made for the same string. Pluralised for the same reason they are: no shipped
                    // template is one step long today, but the shelf is meant to grow, and "1 steps"
                    // beside two lists that say "1 step" is a difference nobody chose.
                    Text(Self.stepCountText(for: template))
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelSecondary)
                        .monospacedDigit()
                }
                .padding(.vertical, DSSpacing.xxs)
                // The rows are the sheet's primary control — you are here to pick one — and they were
                // the only clickable rows in the journey feature that looked identical whether or not
                // the pointer was on them. The journeys list, the journeys navigator and the step
                // list all light up; a macOS `List` gives you selection, not hover.
                .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
                .tag(template.id)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("journeyTemplate-\(template.id)")
                // The count is in the label too, so VoiceOver hears the three facts the row shows
                // rather than the two it used to.
                .accessibilityLabel("\(template.title). \(template.summary) \(Self.stepCountText(for: template)).")
            }
            .frame(height: 320)
            .accessibilityIdentifier("journeyTemplate.list")

            Toggle("Activate once added", isOn: $activate)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("journeyTemplate.activateToggle")
                .accessibilityLabel("Activate once added")

            // The shared sheet button row: `DSSpacing.md` between the buttons, cancel to the left of
            // the confirm action, both `DSButton` at `.medium`. These were bare system `Button`s, so
            // the one sheet reachable from the journeys window was also the only one whose buttons
            // were a different shape, weight and height from every other sheet's.
            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "journeyTemplate.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("journeyTemplate.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Add",
                    variant: .primary,
                    size: .medium,
                    identifier: "journeyTemplate.add"
                ) {
                    onAdd(selection, activate)
                    dismiss()
                }
                // `.return` with no modifiers, matching the other five sheets. `.defaultAction` also
                // confers AppKit's default-button ring, which none of them carry.
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("journeyTemplate.addButton")
                .accessibilityLabel("Add")
            }
        }
        .padding(DSSpacing.lg)
        // A floor and an ideal, like the other five sheets. `width:` pinned this one so it could
        // not be resized at all, alone among them.
        .frame(minWidth: 420, idealWidth: 520)
    }

    /// Singular when there is one. The journeys list and the journeys navigator both spell this the
    /// same way; a template shelf that says "1 steps" is the odd one out.
    private static func stepCountText(for template: JourneyTemplates.Template) -> String {
        let count = template.spec.steps?.count ?? 0
        return "\(count) \(count == 1 ? "step" : "steps")"
    }
}
