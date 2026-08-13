import SwiftUI
import Domain
import DesignSystem

// MARK: - Query

/// The questions the endpoint traffic list asks of the request log, kept out of the view so they can
/// be tested without rendering anything.
///
/// Every `RequestLog` already records the endpoint that answered it, so *"has anything actually
/// called this endpoint?"* has always been answerable — there was simply nothing to ask. Answering it
/// beside the endpoint turns a three-step detour (read the endpoint, open the request log, filter by
/// hand) into a glance.
///
/// Query and view live in one file for the same reason `RequestLogQuery` sits beside
/// `RequestLogDrawerView`: the pure rules and the panel that renders them are read together.
enum EndpointTrafficQuery {
    /// Requests this endpoint answered, newest first.
    ///
    /// Requests that matched a *different* endpoint are excluded, and so are the ones that matched no
    /// endpoint at all — an unmatched call and a journey-answered call both carry a nil
    /// `matchedEndpointID`, and neither belongs to this endpoint's history.
    ///
    /// Two logs can share a timestamp, and `sorted(by:)` makes no stability promise, so the tie is
    /// broken explicitly: the log appends, meaning a later index is a later request, and newest-first
    /// therefore means higher index first. Without that, a list could reshuffle itself between
    /// redraws — which reads as a bug rather than as sorting.
    nonisolated static func logs(forEndpoint endpointID: UUID, in logs: [RequestLog]) -> [RequestLog] {
        logs
            .enumerated()
            .filter { $0.element.matchedEndpointID == endpointID }
            .sorted { left, right in
                if left.element.timestamp == right.element.timestamp {
                    return left.offset > right.offset
                }
                return left.element.timestamp > right.element.timestamp
            }
            .map { $0.element }
    }

    /// A one-line summary for the section header, e.g. `"12 requests · 2 failed"`.
    ///
    /// The failure clause appears only when there is something to report. A permanent "· 0 failed"
    /// would train the eye to skip exactly the clause that matters on the day it is not zero.
    ///
    /// "Failed" means Mimic had nothing configured for the call, or the connection was failed rather
    /// than answered. A configured `500` is *not* a failure: the mock did what it was told.
    nonisolated static func summary(for logs: [RequestLog]) -> String {
        guard logs.isEmpty == false else { return "No requests" }

        var text = "\(logs.count) request\(logs.count == 1 ? "" : "s")"

        let failed = logs.count { $0.outcome.isMissingConfiguration || $0.failureLabel != nil }
        if failed > 0 {
            text += " \u{00B7} \(failed) failed"
        }

        return text
    }

    /// Status codes seen, with how often, most frequent first. For the little distribution row.
    ///
    /// A request that was failed rather than answered has no status code and is left out; it is
    /// already counted by the failure clause in ``summary(for:)``. Folding it in as a `0` would put a
    /// pill on screen for a status no server ever sent.
    ///
    /// Equal counts are ordered by ascending code, because a dictionary has no order of its own and
    /// the row must not rearrange itself every time the view is rebuilt.
    nonisolated static func statusBreakdown(for logs: [RequestLog]) -> [(code: Int, count: Int)] {
        let totals = logs.reduce(into: [Int: Int]()) { totals, log in
            guard let code = log.responseStatusCode else { return }
            totals[code, default: 0] += 1
        }

        return totals
            .map { (code: $0.key, count: $0.value) }
            .sorted { left, right in
                left.count == right.count ? left.code < right.code : left.count > right.count
            }
    }
}

// MARK: - List

/// The traffic one endpoint has actually answered, as a narrow two-line list.
///
/// A list and not a table: the inspector is 220–400pt wide, which is nowhere near enough for the
/// request log's six columns. What survives the narrowing is the status, the time, and the path — and
/// the path is truncated from the *front*, because `/api/v2/users/41` and `/api/v2/users/42` differ
/// at the end.
struct EndpointTrafficList: View {
    /// Already narrowed by ``EndpointTrafficQuery/logs(forEndpoint:in:)``. Filtering again here would
    /// re-run the query on every body evaluation and buy nothing.
    let logs: [RequestLog]
    let onSelect: (UUID) -> Void

    /// No `selectedLogID`, and there cannot usefully be one.
    ///
    /// This list only exists while the inspector is in its `.scenarios` mode, and
    /// `InspectorPanelView.mode` puts `.request` ahead of `.scenarios` — so the instant a log is
    /// selected the panel switches to the request detail and this list is off screen. A selected row
    /// here is a state the panel cannot be in. The parameter existed, defaulted to `nil`, was never
    /// passed at the one call site, and drove an accent stripe that could never draw.
    init(logs: [RequestLog], onSelect: @escaping (UUID) -> Void) {
        self.logs = logs
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            if logs.isEmpty {
                // `DSEmptyState` prefixes whatever it is given, so this renders as
                // `ds.empty.endpointTraffic.empty`, with `.heading` and `.message` beneath it.
                //
                // No summary header above it: the panel-level `DSPanelHeader` still stands, and
                // "No requests" stacked on top of "No traffic yet" would say the same thing twice.
                DSEmptyState(
                    systemImage: "arrow.down.circle",
                    heading: "No traffic yet",
                    message: "Requests that match this endpoint will appear here once the server has answered one.",
                    identifier: "endpointTraffic.empty"
                )
            } else {
                header
                rows
            }
        }
        // The identifier alone would rename every descendant, so no row could be found by its own
        // name — the trap the sidebar's search field fell into. `.contain` names the container and
        // leaves the rows addressable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("endpointTraffic")
    }

    // MARK: - Header

    /// The summary and the status mix, pinned above the scroll view rather than scrolling with it —
    /// a panel's own chrome is not part of its content.
    ///
    /// Two lines rather than a `DSSectionHeader`: at 220pt the summary and the pills do not fit on
    /// one row, and `DSSectionHeader`'s title has no line limit, so a narrow panel would wrap it and
    /// change the header's height under you. The metrics and the hairline are `DSSectionHeader`'s, so
    /// it still reads as the same system.
    @ViewBuilder
    private var header: some View {
        let breakdown = EndpointTrafficQuery.statusBreakdown(for: logs)

        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            // 11pt medium, `DSSectionHeader`'s exact type. This header borrows that component's
            // metrics and hairline already; at regular weight it borrowed everything but the one
            // property that makes a header read as a header.
            Text(EndpointTrafficQuery.summary(for: logs))
                .font(DSTypography.label)
                .fontWeight(.medium)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("endpointTraffic.summary")

            if breakdown.isEmpty == false {
                // Horizontally scrollable so an endpoint with many distinct codes degrades into a
                // scroll rather than silently clipping its last pill.
                ScrollView(.horizontal) {
                    HStack(spacing: DSSpacing.xs) {
                        ForEach(breakdown, id: \.code) { entry in
                            statusChip(code: entry.code, count: entry.count)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No `DSBarHeight` rung, and it should not be given one. This block is one line when an
        // endpoint has answered a single class of response and two when the status chips appear, so it
        // measures 26 or 45 — either side of every rung, and the taller number is the one that carries
        // the distribution. A fixed height would have to clip one of the two states.
        //
        // It does take the band, though. It was the only bar in the window with no background at all,
        // which left it on the inspector's system material while every other strip stated a surface —
        // so this one alone changed tone with the platform rather than with the design.
        .background(DSColors.band)
        // The rows start immediately below this block, so the header needs a stated edge — without
        // it the summary reads as the first row rather than as the panel's own chrome.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
    }

    /// Only a 4xx or 5xx is filled, which is the house rule (`AGENTS.md`: "a filled colour swatch is
    /// for something that needs attention … a column of filled pills is a wall of colour that says
    /// nothing, because everything in it is shouting equally") and matches `pill(text:color:isFilled:)`
    /// twenty lines below — the two spellings sat in this one file disagreeing.
    ///
    /// It is also the reading. A fill is a 12% tint of the label's own colour, so it moves the
    /// surface toward the ink and costs the label 13–18% of its contrast ratio. The three text
    /// tokens `httpStatusColor(for:)` returns absorb that; ``DSColors/accentText`` — the 3xx — does
    /// not, reading 4.48:1 on a panel and 4.35 on the `band` this header is, against a 4.5 floor. No
    /// blue fixes it, because the fill is derived from the label. Not filling a redirect is what
    /// fixes it, and a redirect is not something to stop on.
    private func statusChip(code: Int, count: Int) -> some View {
        let color = DSColors.httpStatusColor(for: code)
        let isFilled = code >= 400

        return Text(verbatim: "\(code) \u{00D7}\(count)")
            .font(DSTypography.caption)
            .foregroundStyle(color)
            // Horizontal inset belongs to the fill, as in `pill` below; the `HStack` carries
            // `DSSpacing.xs` of its own, so an unfilled chip still clears its neighbour.
            .padding(.horizontal, isFilled ? DSSpacing.xs : 0)
            .padding(.vertical, 1)
            .background {
                if isFilled {
                    RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                        .fill(color.opacity(0.12))
                }
            }
            .accessibilityIdentifier("endpointTraffic.status.\(code)")
            .accessibilityLabel("\(count) \(count == 1 ? "response" : "responses") with status \(code)")
    }

    // MARK: - Rows

    /// A plain `VStack` inside the scroll view, deliberately not a `LazyVStack`: one was recently
    /// caught silently dropping the first row of a section in a narrow inspector panel, and an
    /// endpoint's traffic is short enough that laziness would save nothing worth that risk.
    @ViewBuilder
    private var rows: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                    EndpointTrafficRow(
                        log: log,
                        rowIndex: index,
                        onSelect: { onSelect(log.id) }
                    )
                }
            }
        }
    }
}

// MARK: - Row

/// One answered request: status and time on the first line, path on the second.
private struct EndpointTrafficRow: View {
    let log: RequestLog
    let rowIndex: Int
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        // 2pt between the two lines, 6pt above and below the pair: at 4pt the rows ran together
        // into a single striped block, and this list is read by scanning down it.
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HStack(spacing: DSSpacing.xs) {
                statusPill

                Spacer(minLength: DSSpacing.xs)

                Text(log.timestamp, style: .time)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
            }

            // Truncated from the head: the tail of a path is what differs between one call to this
            // endpoint and the next, so cutting the front keeps the informative half.
            Text(log.path)
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        // One element with one spoken label, rather than three fragments VoiceOver would read as
        // "200", "14:32", "/api/users". `.isButton` restores the trait the tap gesture does not
        // carry.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("endpointTraffic.row.\(log.id.uuidString)")
        .accessibilityLabel(spokenLabel)
    }

    private var rowBackground: Color {
        if isHovered { return DSColors.accentSubtle.opacity(0.6) }
        return rowIndex % 2 == 0 ? .clear : DSColors.rowStripe
    }

    /// The status the server returned, or an em dash when the connection was failed rather than
    /// answered.
    ///
    /// `RequestLogTableRow` renders a missing code as `0`, which it can afford because it also shows
    /// an outcome column. This row has no such column, and a `0` pill would read as a status the
    /// server actually sent.
    ///
    /// Only failures wear the filled pill. Every row in this panel is a request to the *same*
    /// endpoint, so a filled swatch on each one stacked into a column of colour that said nothing —
    /// and the 500 you were looking for sat in it at the same volume as forty 200s. The colour still
    /// carries the class of the code, it just stops shouting it.
    @ViewBuilder
    private var statusPill: some View {
        if let code = log.responseStatusCode {
            pill(text: "\(code)", color: DSColors.httpStatusColor(for: code), isFilled: code >= 400)
        } else {
            // No code at all is a failure by definition, so it keeps the fill — and because `pill`
            // draws that fill as a 12% tint of this very colour, it takes `destructiveText` for the
            // same reason `httpStatusColor(for:)` returns the text variants. The base red reads
            // 4.07:1 on a panel here, under the 4.5 the palette holds itself to.
            pill(text: "\u{2014}", color: DSColors.destructiveText, isFilled: true)
        }
    }

    private func pill(text: String, color: Color, isFilled: Bool) -> some View {
        Text(text)
            .font(DSTypography.codeSmall)
            .foregroundStyle(color)
            // Horizontal inset belongs to the fill: without one, the bare code sits flush with the
            // path below it instead of 4pt to its right. The vertical inset is paid on both so a row
            // does not change height with its status code.
            .padding(.horizontal, isFilled ? DSSpacing.xs : 0)
            .padding(.vertical, 1)
            .background {
                if isFilled {
                    RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                        .fill(color.opacity(0.12))
                }
            }
    }

    /// What VoiceOver reads for the row. Named `spokenLabel` rather than `accessibilityLabel` so it
    /// cannot be confused with the modifier of that name.
    private var spokenLabel: String {
        if let code = log.responseStatusCode {
            return "\(log.method.rawValue) \(log.path), status \(code)"
        }
        if let failureLabel = log.failureLabel {
            return "\(log.method.rawValue) \(log.path), failed: \(failureLabel)"
        }
        return "\(log.method.rawValue) \(log.path), no response"
    }
}
