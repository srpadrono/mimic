import SwiftUI
import Domain
import DesignSystem

/// Geometry shared by every label/value row the inspector draws, whichever mode the panel is in.
///
/// Xcode's inspectors right-align the label in a fixed column and start every value at the same x,
/// which gives one vertical seam down the panel instead of two columns pinned to opposite edges with
/// a canyon between them. The seam has to be a constant rather than a per-view number: the overview
/// and the request detail are the *same* 280pt column, and a seam that shifted when you clicked a
/// logged request would read as the panel re-laying itself out.
enum InspectorRowMetrics {
    /// Width of the right-aligned label column in the request detail.
    ///
    /// Sized for "Response headers", its longest label, which measures 90.7pt at
    /// `DSTypography.caption` (SF Pro 10pt medium). Anything longer must raise this rather than wrap:
    /// a two-line label breaks the baseline alignment with its value.
    static let detailLabelColumn: CGFloat = 92

    /// Width of the right-aligned label column in the overview.
    ///
    /// Deliberately narrower than the detail's. The two panels are never on screen together — one
    /// replaces the other — so a shared seam buys nothing, and forcing the overview to 92pt for a
    /// label set whose longest member is "Unmatched" (about 58pt) left its rows floating in the
    /// middle of the panel while the section headings stayed flush left. A right-aligned column only
    /// reads as a column when it is roughly the width of its contents.
    static let overviewLabelColumn: CGFloat = 66

    /// Where the overview's value column starts, measured from the panel's leading edge. Anything
    /// belonging to a value rather than to the row as a whole lines up here.
    static let overviewValueInset: CGFloat = DSSpacing.md + overviewLabelColumn + DSSpacing.sm
}

/// What the inspector shows when no endpoint is selected.
///
/// The panel used to reserve 280pt of window to say "No selection" — a permanent void, since nothing
/// is selected for most of a session. Rather than collapse the panel (which makes the layout jump
/// every time you click), it now answers the questions you would otherwise go looking for: is the
/// server up, on which port, is a journey overriding my mocks, and is anything arriving that I have
/// not mocked.
///
/// The unmatched count is the one that earns its place. It is the signal that something is wrong with
/// your configuration, and it was previously only visible if the request log happened to be open.
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
            // No spacing and no outer padding: the section bands are the separation, and rows carry
            // their own horizontal padding so their seam lands at the same x as the request detail's.
            VStack(alignment: .leading, spacing: 0) {
                section("Server") {
                    row("Status", value: serverStatusText, valueColor: serverStatusColor)
                    row("Port", value: "\(summary.port)")
                }

                section("Configuration") {
                    row("Endpoints", value: "\(summary.endpointCount)")
                    row("Scenarios", value: "\(summary.scenarioCount)")
                    row("Journeys", value: "\(summary.journeyCount)")
                }

                section("Active journey") {
                    if let name = summary.activeJourneyName {
                        row("Name", value: name, valueColor: DSColors.accentText)
                        if let progress = summary.activeJourneyProgress {
                            row("Progress", value: progress)
                        }
                        // `DSButton`'s ghost variant, not `.buttonStyle(.link)` and no longer a
                        // hand-rolled `.plain` button either. Link style was the only AppKit link in
                        // the window: it draws its own blue and its own underline-on-hover, neither of
                        // which matches the accent text buttons around it, and it gave a ~13pt-tall
                        // hit target. What replaced it — accent text, 20pt tall, `accentSubtle` under
                        // the pointer — was `DSButton(.ghost, .small)` written out by hand, down to
                        // the corner radius. So it is that now, and the copy bar's three are too.
                        // "Show", not "Open". It used to open the standalone journeys window; it now
                        // switches the navigator to its Journeys tab, which is where journeys live.
                        // "Open" promises a window, and a label that names the wrong outcome is worse
                        // than a vague one — you press it expecting somewhere new and the sidebar
                        // changes underneath you instead.
                        DSButton(
                            "Show journeys",
                            variant: .ghost,
                            size: .small,
                            identifier: "inspector.overview.openJourneys",
                            action: onShowJourneys
                        )
                        .accessibilityIdentifier("inspector.overview.openJourneys")
                        // A control that acts on the journey above it, so it starts where that
                        // journey's name does rather than at the panel edge. Subtracting the button's
                        // own horizontal padding — `sm` at this size — keeps the text on the seam.
                        .padding(.leading, InspectorRowMetrics.overviewValueInset - DSSpacing.sm)
                        .padding(.trailing, DSSpacing.md)
                        .padding(.vertical, DSSpacing.xs + 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        note(
                            "None — endpoints answer directly.",
                            identifier: "inspector.overview.activeJourney.none"
                        )
                    }
                }

                section("Traffic") {
                    row("Requests", value: "\(summary.requestCount)")
                    row(
                        "Unmatched",
                        value: "\(summary.unmatchedCount)",
                        // Amber only when there is something to look at; a zero here is good news
                        // and should not read as a warning.
                        valueColor: summary.unmatchedCount > 0
                            ? DSColors.httpStatusColor(for: 404)
                            : DSColors.labelSecondary
                    )
                    if summary.unmatchedCount > 0 {
                        note(
                            "Requests arrived that no endpoint or journey answered.",
                            identifier: "inspector.overview.unmatched.note"
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, DSSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.contain` before the identifier, the way the journey editor's step list orders it. A
        // named container without it renames every descendant to match — the rows, the notes and
        // `inspector.overview.openJourneys` all reported `inspector.overview`, which left the one
        // button in this panel unaddressable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.overview")
    }

    // MARK: - Pieces

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The component, not a copy of it. This used to be a private `sectionHeader` that
            // reproduced `DSSectionHeader` value for value — same 12/5 padding, same
            // `tertiary.opacity(0.5)` band, same 0.5pt rule, same 11pt medium label. Two copies of
            // one band, in the *same panel*: the overview drew one and the request detail drew the
            // real component, so any edit to `DSSectionHeader` would have desynchronised the two
            // halves of the inspector. It also had no `ds.sectionheader.*` identifier.
            DSSectionHeader(title, identifier: "overview.\(title.lowercased())")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label right-aligned in a fixed column, value flush left in what is left — the macOS inspector
    /// convention. The old layout pushed the two apart with a `Spacer`, which in a 280pt panel gave
    /// two edge-pinned columns and a ragged right edge of values.
    @ViewBuilder
    private func row(
        _ label: String,
        value: String,
        valueColor: Color = DSColors.labelSecondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Text(label)
                .font(DSTypography.caption)
                // `labelSecondary`. These are read, not glanced past — at 36% alpha they measure
                // 2.5:1, and `labelTertiary` is for timestamps and separators.
                .foregroundStyle(DSColors.labelSecondary)
                .frame(width: InspectorRowMetrics.overviewLabelColumn, alignment: .trailing)
            Text(value)
                .font(DSTypography.codeSmall)
                .foregroundStyle(valueColor)
                // Wrap rather than truncate: a journey name is the one value here long enough to
                // need it, and a middle-truncated name is unreadable.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs + 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector.overview.\(label.lowercased())")
    }

    /// Explanatory prose under a section's rows. Full width rather than in the value column: these
    /// wrap, and 158pt would turn one sentence into four lines.
    ///
    /// The identifier is passed in rather than derived from the message, the way
    /// `EndpointEditorView.validationNote` takes its own: these sentences are the panel's answer to
    /// "is a journey overriding my mocks" and "is anything arriving unmatched", so a test asserts on
    /// the note being present, not on the prose staying word for word.
    @ViewBuilder
    private func note(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(DSTypography.caption)
            // "Requests arrived that no endpoint answered" is the point of the panel, not a hint.
            .foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.xs + 1)
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
        case .running: DSColors.serverRunning
        case .error: DSColors.destructive
        default: DSColors.labelSecondary
        }
    }
}
