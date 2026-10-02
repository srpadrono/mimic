import DesignSystem
import Domain
import Foundation
import Observation
import SwiftUI

// MARK: - Column & Sort Constants

/// The log's column widths. The header cells and the row cells read these same numbers, so a
/// column's title always sits over its own values. Path is the one flexible column.
enum LogColumns {
    /// The table's own inset inside the pane; each cell adds `DSSpacing.sm` of padding on both sides.
    static let tableInset: CGFloat = 6

    /// Fits a 12-hour timestamp with milliseconds ("11:41:33.123 PM") in the mono figure face.
    static let time: CGFloat = 128
    /// Fits a 24-hour timestamp with milliseconds ("21:46:12.418"), the width the design draws.
    static let twentyFourHourTime: CGFloat = 110
    /// The compact table's time: seconds, no milliseconds and no day period ("11:41:33").
    static let compactTime: CGFloat = 76
    static let method: CGFloat = 64
    static let status: CGFloat = 84
    static let scenario: CGFloat = 150
    static let duration: CGFloat = 84
    /// Fits "1023 KB", the widest reading ``RequestLogQuery/formattedBytes(_:)`` produces.
    static let size: CGFloat = 76

    /// The narrowest Path worth drawing before the full table gives way to the compact one.
    static let minimumPath: CGFloat = 160
    /// The narrowest Path the compact table draws, middle-truncated, before it scrolls sideways.
    /// Small on purpose: in a narrow drawer Status staying on screen matters more than more path.
    static let compactMinimumPath: CGFloat = 56

    /// Below this the table drops Scenario, Duration and Size and shortens Time. Measured with the
    /// wider 12-hour time, so the switch happens at one width whatever the clock.
    static let minimumTableWidth = time + method + minimumPath + status + scenario + duration + size
        + tableInset * 2

    /// Below this even the compact table scrolls sideways.
    static let compactMinimumTableWidth = compactTime + method + compactMinimumPath + status + tableInset * 2

    static func timeWidth(compact: Bool, twentyFourHour: Bool = false) -> CGFloat {
        if compact { return compactTime }
        return twentyFourHour ? twentyFourHourTime : time
    }

    /// Whether `locale` reads the time on a 24-hour clock. The environment's locale carries the
    /// Mac's own 12- or 24-hour choice, which the timestamps follow.
    static func usesTwentyFourHourClock(_ locale: Locale) -> Bool {
        locale.hourCycle == .zeroToTwentyThree || locale.hourCycle == .oneToTwentyFour
    }

    /// The list beside an open request: Time, Method, Path and Status.
    static let splitList: CGFloat = 520

    /// The list's width beside an open request: 520pt, as drawn, giving way on a narrow window so
    /// the detail keeps at least half the column, but never narrower than the compact table.
    static func splitListWidth(totalWidth: CGFloat) -> CGFloat {
        max(compactMinimumTableWidth, min(splitList, totalWidth / 2))
    }

    /// Header and rows must receive the same resolved path width, or a vertical scrollbar in the
    /// rows would shift every column after Path.
    static func pathWidth(tableWidth: CGFloat, compact: Bool, twentyFourHour: Bool = false) -> CGFloat {
        let fixedWidth = compact
            ? compactTime + method + status
            : timeWidth(compact: false, twentyFourHour: twentyFourHour) + method + status + scenario + duration + size
        return max(0, tableWidth - fixedWidth - tableInset * 2)
    }
}

/// Which slice of the log the segmented control shows.
enum LogScope: Hashable {
    case all, unmatched, errors
}

public enum SortField: String {
    case method, path, endpoint, scenario, status, timestamp
}

/// What the request log table is showing: its filter, its sort, and the rows those produce.
///
/// One instance is owned by `WorkspaceView` and handed to both places the log appears — docked under
/// the editor, and in the centre column beside an open request — so moving between the two keeps
/// the filter, the sort and the rows already computed instead of redrawing an empty table first.
@Observable
@MainActor
public final class RequestLogTableState {
    var filterText: String
    var methodFilter: HTTPMethod?
    var errorsOnly: Bool
    var sortField: SortField
    var sortAscending: Bool
    /// The filtered, sorted rows, written by the table once its background pass finishes. `nil`
    /// until the first pass has run; the table works its first rows out on the spot meanwhile, so
    /// it never opens on an empty frame.
    var rows: [RequestLog]?
    var selectionAnchorID: UUID?
    /// The detail's tab, kept as the selection moves from one request to the next.
    var detailTab: RequestDetailTab = .request

    public init(
        filterText: String = "",
        methodFilter: HTTPMethod? = nil,
        errorsOnly: Bool = false,
        sortField: SortField = .timestamp,
        sortAscending: Bool = false
    ) {
        self.filterText = filterText
        self.methodFilter = methodFilter
        self.errorsOnly = errorsOnly
        self.sortField = sortField
        self.sortAscending = sortAscending
    }
}

public enum RequestLogQuery {
    nonisolated static func process(
        logs: [RequestLog],
        endpoints: [Endpoint],
        methodFilter: HTTPMethod?,
        filterText: String,
        unmatchedOnly: Bool = false,
        errorsOnly: Bool = false,
        sortField: SortField,
        sortAscending: Bool
    ) -> [RequestLog] {
        // Every predicate here is `RequestLogFilter` in Domain, which `HostReport.requestLog` also
        // calls. The rules used to be written twice — here for the drawer's rows, and again for the
        // `logList` command — so `mimic log list --unmatched` and the drawer's own toggle were two
        // separate answers to one question, agreeing only because nobody had changed either.
        //
        // Sorting stays here. It is not a rule about which requests matter, it is a rule about how a
        // *table* orders itself, and it needs `endpoints` to resolve the "Answered by" column — which
        // is view state, not a property of the log.
        var filteredLogs = RequestLogFilter(
            unmatchedOnly: unmatchedOnly,
            method: methodFilter
        ).apply(to: logs)

        if errorsOnly {
            filteredLogs = filteredLogs.filter(isError)
        }

        // The text rules are `RequestLogFilter`'s, widened here to the endpoint and scenario names,
        // which only the view can resolve.
        if !filterText.isEmpty {
            let textFilter = RequestLogFilter(text: filterText)
            filteredLogs = filteredLogs.filter { log in
                if textFilter.matches(log) { return true }
                let names = [
                    endpointName(for: log.matchedEndpointID, endpoints: endpoints),
                    scenarioName(endpointID: log.matchedEndpointID, scenarioID: log.matchedScenarioID,
                                 endpoints: endpoints),
                ]
                return names.contains { $0?.localizedCaseInsensitiveContains(filterText) == true }
            }
        }

        // Descending is the ascending predicate with its **operands** swapped, never its answer
        // negated. This used to end on `sortAscending ? result : !result`, and `!(a < b)` is `a >= b`:
        // for two rows whose keys are equal it answered *true* in both directions, so the comparator
        // simultaneously claimed left precedes right and right precedes left. `sort(by:)` requires a
        // strict weak ordering and promises nothing about its output when it does not get one — the
        // result was not "the ascending one reversed", it was whatever the sort's internals happened
        // to do with a contradiction. Ties are not the exotic case here either: a session repeats
        // methods, paths, status codes, endpoint names and scenario names constantly, and the
        // timestamp is the only column of the six that does not normally hold duplicates at all.
        filteredLogs.sort { left, right in
            sortAscending
                ? isOrderedBefore(left, right, sortField: sortField, endpoints: endpoints)
                : isOrderedBefore(right, left, sortField: sortField, endpoints: endpoints)
        }

        return filteredLogs
    }

    /// Whether `left` belongs before `right` with the column sorted ascending.
    ///
    /// One direction only, on purpose: the other is this with the operands swapped — see the note at
    /// the call site for what negating the answer instead did to equal rows.
    ///
    /// Rows whose sorted column is equal fall through to the timestamp. That secondary key is what
    /// makes the order *fully specified* rather than merely legal: `sort(by:)` is not documented as
    /// stable, so on a column with duplicates two equal rows are otherwise free to swap places on
    /// every re-sort, and the log would redraw in a different order after an unrelated filter
    /// keystroke. It reverses along with everything else, so descending puts the newest of a set of
    /// equals first. Two entries carrying the same timestamp *and* the same key compare equal in both
    /// directions, which is precisely what a strict weak ordering asks for.
    nonisolated static func isOrderedBefore(
        _ left: RequestLog,
        _ right: RequestLog,
        sortField: SortField,
        endpoints: [Endpoint]
    ) -> Bool {
        switch sortField {
        case .method:
            if left.method.rawValue != right.method.rawValue {
                return left.method.rawValue < right.method.rawValue
            }
        case .path:
            if left.path != right.path {
                return left.path < right.path
            }
        case .endpoint:
            let leftName = endpointName(for: left.matchedEndpointID, endpoints: endpoints) ?? ""
            let rightName = endpointName(for: right.matchedEndpointID, endpoints: endpoints) ?? ""
            if leftName != rightName { return leftName < rightName }
        case .scenario:
            let leftName = scenarioName(
                endpointID: left.matchedEndpointID,
                scenarioID: left.matchedScenarioID,
                endpoints: endpoints
            ) ?? ""
            let rightName = scenarioName(
                endpointID: right.matchedEndpointID,
                scenarioID: right.matchedScenarioID,
                endpoints: endpoints
            ) ?? ""
            if leftName != rightName { return leftName < rightName }
        case .status:
            let leftCode = left.responseStatusCode ?? 0
            let rightCode = right.responseStatusCode ?? 0
            if leftCode != rightCode { return leftCode < rightCode }
        case .timestamp:
            break
        }

        return left.timestamp < right.timestamp
    }

    /// The path to mock for a logged request: the query string is dropped, because it is a property
    /// of the call and not of the route.
    nonisolated static func mockablePath(from path: String) -> String {
        // `split` omits empty subsequences, so a query-only path such as "?a=1" would otherwise come
        // back as "a=1" — not a route at all. Cut at the separator instead.
        let withoutQuery = path.firstIndex(of: "?").map { String(path[path.startIndex..<$0]) } ?? path
        return withoutQuery.hasPrefix("/") ? withoutQuery : "/"
    }

    /// How many logged requests had nothing configured for them.
    public nonisolated static func unmatchedCount(logs: [RequestLog]) -> Int {
        logs.count { $0.outcome.isMissingConfiguration }
    }

    /// A 4xx or 5xx answer, or no answer at all.
    nonisolated static func isError(_ log: RequestLog) -> Bool {
        guard let code = log.responseStatusCode else { return true }
        return code >= 400
    }

    /// How many logged requests the Errors filter would show.
    nonisolated static func errorCount(logs: [RequestLog]) -> Int {
        logs.count(where: isError)
    }

    /// Hours, minutes, seconds and milliseconds, in the reader's 12- or 24-hour convention.
    nonisolated static let timestampFormat: Date.FormatStyle = .dateTime
        .hour().minute().second().secondFraction(.fractional(3))

    /// The compact table's time: hours, minutes and seconds, without the day period, so a narrow
    /// drawer keeps room for Path and Status. The full reading is in the request's inspector.
    nonisolated static let compactTimestampFormat: Date.FormatStyle = .dateTime
        .hour(.defaultDigits(amPM: .omitted)).minute().second()

    /// "8 ms", or "1.2 s" from a second up.
    nonisolated static func formattedDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }

    /// The response's size, from its logged body or its Content-Length. `nil` when no response arrived
    /// or neither says.
    nonisolated static func formattedSize(for log: RequestLog) -> String? {
        let bytes: Int
        if let body = log.responseBody, !body.isEmpty, !log.responseBodyTruncated {
            bytes = body.utf8.count
        } else if let header = log.responseHeaders.first(where: {
            $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame
        }), let length = Int(header.value.trimmingCharacters(in: .whitespaces)) {
            bytes = length
        } else if log.responseBodyIsBinary == true || log.responseBodyTruncated
                    || log.responseStatusCode == nil {
            // No status means no response arrived, so there is no size to report; an empty
            // answer with a status (a 204) is genuinely zero bytes.
            return nil
        } else {
            bytes = log.responseBody?.utf8.count ?? 0
        }
        return formattedBytes(bytes)
    }

    nonisolated static func formattedBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return scaled(Double(bytes) / 1024, unit: "KB") }
        return scaled(Double(bytes) / (1024 * 1024), unit: "MB")
    }

    /// One decimal below 100 ("68.4 KB"), whole numbers from there ("312 KB"), so no reading is
    /// wider than seven characters and the Size column stays at the design's width. Rounded down,
    /// so 1023.9 KB reads "1023 KB" rather than a "1024 KB" that ought to be "1.0 MB".
    private nonisolated static func scaled(_ value: Double, unit: String) -> String {
        value < 99.95 ? String(format: "%.1f \(unit)", value) : "\(Int(value)) \(unit)"
    }

    nonisolated static func endpointName(for endpointID: UUID?, endpoints: [Endpoint]) -> String? {
        guard let endpointID else { return nil }
        return endpoints.first { $0.id == endpointID }?.name
    }

    nonisolated static func scenarioName(endpointID: UUID?, scenarioID: UUID?, endpoints: [Endpoint]) -> String? {
        guard let endpointID, let scenarioID else { return nil }
        guard let endpoint = endpoints.first(where: { $0.id == endpointID }) else { return nil }
        return endpoint.scenarios.first { $0.id == scenarioID }?.name
    }
}

