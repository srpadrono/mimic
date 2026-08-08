import SwiftUI
import Domain
import DesignSystem

/// The journeys empty state, as a teaching surface.
///
/// **This is the highest-value idea in the redesign.** Journeys are the app's most valuable feature
/// and its least obvious, and the nine built-in templates teach the concept better than any
/// paragraph does — but they sat two clicks deep behind a `+` menu and a list sheet, so the screen a
/// new user actually met said "No journeys yet" and offered nothing to look at.
///
/// Each card shows its template's **actual step sequence**, read from shipped data: `200 → 500 →
/// 200 → 200` demonstrates "a route that answers differently the second time" in one glance, which
/// is the sentence the copy was struggling to write.
struct JourneyTemplateGallery: View {
    let templates: [JourneyTemplates.Template]
    let onCreate: (JourneyTemplates.Template) -> Void
    let onStartEmpty: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: DSSpacing.md, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    intro

                    LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpacing.md) {
                        ForEach(templates) { template in
                            JourneyTemplateCard(template: template) { onCreate(template) }
                        }
                    }
                }
                .padding(.horizontal, DSSpacing.xl)
                .padding(.vertical, DSSpacing.lgPlus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeys.templateGallery")
    }

    private var header: some View {
        DSPanelHeader("Journeys", identifier: "journeyGallery") {
            DSButton(
                "Start empty",
                variant: .secondary,
                size: .small,
                identifier: "journeys.startEmpty",
                action: onStartEmpty
            )
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            // The question the feature answers, asked in the user's words rather than the domain's.
            // "Journey" means nothing until you have seen one; "what does this route return the
            // second time?" is a problem people recognise.
            Text("A journey answers \u{201C}what does this route return the second time?\u{201D}")
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
                An endpoint gives a route one answer. A journey scripts a sequence — so a retry can \
                succeed after a failure, a token can expire mid-session, or a poll can stay pending \
                and then complete. Pick one to see how it is built.
                """)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelSecondary)
                .lineSpacing(DSTypography.Leading.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

/// One template, with its step sequence as the thing you actually read.
private struct JourneyTemplateCard: View {
    let template: JourneyTemplates.Template
    let onCreate: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onCreate) {
            VStack(alignment: .leading, spacing: DSSpacing.mdMinus) {
                Text(template.title)
                    .font(DSTypography.bodyBold)
                    .foregroundStyle(DSColors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Text(template.summary)
                    .font(DSTypography.meta)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineSpacing(DSTypography.Leading.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                stepSequence
            }
            .padding(DSSpacing.mdPlus)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DSCornerRadius.lgPlus)
                    .fill(DSColors.surfaceElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSCornerRadius.lgPlus)
                    .stroke(DSColors.border, lineWidth: 0.5)
            }
            .shadow(
                color: .black.opacity(isHovered ? 0.10 : 0.05),
                radius: isHovered ? 4 : 2,
                y: isHovered ? 2 : 1
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help("Create a journey from \u{201C}\(template.title)\u{201D}")
        .accessibilityIdentifier("journeys.template.\(template.id)")
        .accessibilityLabel(accessibilityDescription)
    }

    private var steps: [JourneyStepSpec] { template.spec.steps ?? [] }

    /// The card's whole reason to exist: what this journey actually does, in order.
    private var stepSequence: some View {
        HStack(spacing: DSSpacing.xs) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityHidden(true)
                }
                JourneyTemplateStepChip(step: step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Spoken as a sentence, because a row of status codes read one chip at a time is noise.
    private var accessibilityDescription: String {
        let sequence = steps.map { step -> String in
            if step.failure != nil { return "connection drops" }
            return step.statusCode.map(String.init) ?? "no response"
        }
        return "\(template.title). \(template.summary) Steps: \(sequence.joined(separator: ", then "))."
    }
}

/// One step, as a status chip — or a word, when no status code can express it.
private struct JourneyTemplateStepChip: View {
    let step: JourneyStepSpec

    var body: some View {
        Group {
            if step.failure != nil {
                // A transport failure has no status code, so it gets a word. Drawing it as "000" or
                // an empty chip would say the server answered something.
                Text("drop")
                    .font(DSTypography.metaBold)
                    .foregroundStyle(DSColors.destructiveDeep)
                    .padding(.horizontal, DSSpacing.xs)
                    .frame(height: 16)
                    .background {
                        RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                            .fill(DSColors.destructive.opacity(0.13))
                    }
            } else if let code = step.statusCode {
                DSStatusCodeBadge(code: code, identifier: "templateStep")
            }
        }
    }
}
