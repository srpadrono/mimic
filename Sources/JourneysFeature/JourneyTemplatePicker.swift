import DesignSystem
import Domain
import SwiftUI

/// Picks a journey off the built-in shelf.
///
/// The templates cover the scenarios teams reproduce most often, and each is also a worked example of
/// the step vocabulary — so starting here is faster *and* teaches the shape of a journey.
public struct JourneyTemplatePicker: View {
    @Environment(\.dismiss) private var dismiss

    /// `(templateID, activateImmediately)`
    let onAdd: (String, Bool) -> Void

    @State private var selection: String = JourneyTemplates.all.first?.id ?? ""
    @State private var activate = true

    public init(onAdd: @escaping (String, Bool) -> Void) {
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Add a journey from a template")
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Each template is a worked example you can edit after adding it.")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
            }

            List(JourneyTemplates.all, selection: $selection) { template in
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                        Text(template.title)
                            .font(DSTypography.bodyMedium)
                            .foregroundStyle(DSColors.labelPrimary)
                        Spacer(minLength: DSSpacing.sm)
                        Text(Self.stepCountText(for: template))
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.labelSecondary)
                            .monospacedDigit()
                    }

                    // Wraps rather than truncates: a `List` row gets a bounded width.
                    Text(template.summary)
                        .font(DSTypography.callout)
                        .foregroundStyle(DSColors.labelSecondary)
                        .lineSpacing(DSTypography.Leading.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, DSSpacing.sm)
                .padding(.horizontal, DSSpacing.xs)
                // A macOS `List` gives selection but not hover.
                .dsHoverHighlight(cornerRadius: DSCornerRadius.field)
                .tag(template.id)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("journeyTemplate-\(template.id)")
                .accessibilityLabel("\(template.title). \(template.summary) \(Self.stepCountText(for: template)).")
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("journeyTemplate.list")
            .background(DSColors.content)
            .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.card)
                    .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                    .allowsHitTesting(false)
            }
            .frame(height: 320)

            HStack(spacing: DSSpacing.sm) {
                Toggle("Activate once added", isOn: $activate)
                    .toggleStyle(.checkbox)
                    .font(DSTypography.body)
                    .accessibilityIdentifier("journeyTemplate.activateToggle")
                    .accessibilityLabel("Activate once added")

                Spacer()

                DSButton(
                    "Cancel",
                    variant: .secondary,
                    size: .large,
                    identifier: "journeyTemplate.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("journeyTemplate.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Add",
                    variant: .primary,
                    size: .large,
                    identifier: "journeyTemplate.add"
                ) {
                    onAdd(selection, activate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("journeyTemplate.addButton")
                .accessibilityLabel("Add")
            }
            .padding(.top, DSSpacing.sm)
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.medium)
        .background(DSColors.sheet)
        .dsSheetSurface()
    }

    /// Singular when there is one, as the journeys list spells it.
    private static func stepCountText(for template: JourneyTemplates.Template) -> String {
        let count = template.spec.steps?.count ?? 0
        return "\(count) \(count == 1 ? "step" : "steps")"
    }
}
