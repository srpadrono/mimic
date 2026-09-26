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

    /// The summary and status distribution remain above the scrolling request list.
    @ViewBuilder
    private var header: some View {
        let breakdown = EndpointTrafficQuery.statusBreakdown(for: logs)

        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(EndpointTrafficQuery.summary(for: logs))
                .font(DSTypography.labelMedium)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("endpointTraffic.summary")

            if breakdown.isEmpty == false {
                // Keep every status reachable when the distribution exceeds the panel width.
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
        .padding(.horizontal, DSInspectorMetrics.inset)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The summary grows with its status distribution and inherits the inspector material.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
    }

    /// Keep the distribution available with the same quiet status text used in traffic rows.
    private func statusChip(code: Int, count: Int) -> some View {
        HStack(spacing: DSSpacing.xs) {
            DSInspectorStatus(statusCode: code)
            Text("×\(count)").font(DSTypography.metaSmall).foregroundStyle(DSColors.labelSecondary)
        }
            .accessibilityElement(children: .ignore)
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
                ForEach(logs) { log in
                    EndpointTrafficRow(
                        log: log,
                        onSelect: { onSelect(log.id) }
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("endpointTraffic.list")
    }
}

// MARK: - Row

/// One answered request: path and status, followed by time and duration.
private struct EndpointTrafficRow: View {
    let log: RequestLog
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: DSSpacing.smPlus) {
                    Text(log.path)
                        .font(DSTypography.codePath)
                        .foregroundStyle(DSColors.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DSInspectorStatus(statusCode: log.responseStatusCode, failure: log.failureLabel)
                }
                HStack {
                    Text(log.timestamp, style: .time)
                    Spacer(minLength: DSSpacing.sm)
                    if let duration = log.durationMs { Text("\(duration) ms").monospacedDigit() }
                }
                .font(DSTypography.metaSmall)
                .foregroundStyle(DSColors.labelSecondary)
            }
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.vertical, DSSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
        .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
        .help(spokenLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("endpointTraffic.row.\(log.id.uuidString)")
        .accessibilityLabel(spokenLabel)
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
