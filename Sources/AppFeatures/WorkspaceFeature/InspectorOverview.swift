import SwiftUI
import Domain
import DesignSystem

/// Geometry shared by every label/value row the inspector draws, whichever mode the panel is in.
/// Labels sit in one fixed column so values start at the same x in the overview and the request detail.
enum InspectorRowMetrics {
    static let detailLabelColumn = DSInspectorMetrics.labelColumn
    static let overviewLabelColumn = DSInspectorMetrics.labelColumn
    /// Where a value starts: the inset, the label column, and the row's own gap.
    static let overviewValueInset = DSInspectorMetrics.inset + DSInspectorMetrics.labelColumn + DSSpacing.md
}

/// What the inspector shows when nothing is selected: the server, the project's size, whether a
/// journey is overriding mocks, and whether anything arrived that nothing answered.
struct InspectorOverview: View {
    struct Summary: Equatable {
        var projectName: String
        var serverState: ServerState
        var port: Int
        var endpointCount: Int
        var scenarioCount: Int
        var journeyCount: Int
        var activeJourneyName: String?
        var activeJourneyProgress: String?
        var requestCount: Int
        var unmatchedCount: Int
    }

    let summary: Summary
    let onShowJourneys: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Server") {
                    row("Status", value: serverStatusText, valueColor: serverStatusColor)
                    row("Port", value: "\(summary.port)", valueColor: DSColors.labelPrimary)
                }

                section("Configuration") {
                    row("Endpoints", value: "\(summary.endpointCount)", valueColor: DSColors.labelPrimary)
                    row("Scenarios", value: "\(summary.scenarioCount)", valueColor: DSColors.labelPrimary)
                    row("Journeys", value: "\(summary.journeyCount)", valueColor: DSColors.labelPrimary)
                }

                section(summary.serverState.runningPort == nil ? "Selected journey" : "Active journey") {
                    if let name = summary.activeJourneyName {
                        row("Name", value: name, valueColor: DSColors.accent)
                        if let progress = summary.activeJourneyProgress {
                            row("Progress", value: progress, valueColor: DSColors.labelPrimary)
                        }
                        // "Show", not "Open": it switches the navigator to Journeys, it opens no window.
                        DSButton(
                            "Show journeys",
                            variant: .secondary,
                            size: .medium,
                            identifier: "inspector.overview.openJourneys",
                            action: onShowJourneys
                        )
                        .accessibilityIdentifier("inspector.overview.openJourneys")
                        .padding(.leading, InspectorRowMetrics.overviewValueInset)
                        .padding(.trailing, DSInspectorMetrics.inset)
                        .padding(.top, DSSpacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        note(
                            "None. Endpoints answer directly.",
                            identifier: "inspector.overview.activeJourney.none"
                        )
                    }
                }

                section("Traffic") {
                    HStack(alignment: .top, spacing: DSSpacing.lg) {
                        figure(
                            "Requests",
                            caption: summary.requestCount == 1 ? "request" : "requests",
                            value: summary.requestCount,
                            color: DSColors.labelPrimary
                        )
                        figure(
                            "Unmatched",
                            caption: "unmatched",
                            value: summary.unmatchedCount,
                            // Warning only when there is something to look at; zero is good news.
                            color: summary.unmatchedCount > 0 ? DSColors.warning : DSColors.labelPrimary
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DSInspectorMetrics.inset)
                    .padding(.top, DSSpacing.xxs)

                    if summary.unmatchedCount > 0 {
                        note(
                            "Requests arrived that no endpoint or journey answered.",
                            identifier: "inspector.overview.unmatched.note"
                        )
                    }
                }
            }
            .padding(.bottom, DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            // On the content group, not the scroll view: XCUITest finds no element for an
            // identifier set on a `ScrollView`. `.contain` before the identifier, so rows and the
            // button keep their own names.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector.overview")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DSInspectorSectionHeader(title, identifier: "overview.\(title.lowercased())")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(
        _ label: String,
        value: String,
        valueColor: Color = DSColors.labelSecondary
    ) -> some View {
        DSInspectorValueRow(label, value: value, color: valueColor,
                            identifier: "inspector.overview.\(label.lowercased())")
    }

    /// A large figure over a small caption, as the inspector's traffic summary draws them.
    /// Spoken as "Label: value" under the same identifier a value row would carry.
    private func figure(_ label: String, caption: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(DSTypography.Figure.large)
                .foregroundStyle(color)
                .lineLimit(1)
            Text(caption)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityIdentifier("inspector.overview.\(label.lowercased())")
    }

    /// Explanatory prose under a section, full width because it wraps.
    @ViewBuilder
    private func note(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .lineSpacing(DSTypography.Leading.callout - 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.vertical, DSSpacing.xs + 2)
            .accessibilityIdentifier(identifier)
    }

    private var serverStatusText: String {
        switch summary.serverState {
        case .stopped: "Stopped"
        case .starting: "Starting\u{2026}"
        case .running: "Running"
        case .stopping: "Stopping\u{2026}"
        case .error: "Error"
        }
    }

    private var serverStatusColor: Color {
        switch summary.serverState {
        case .running: DSColors.success
        case .error: DSColors.error
        default: DSColors.labelSecondary
        }
    }
}
