import Foundation
import Domain

// MARK: - Query

/// The questions the request log can answer about one endpoint.
///
/// Every `RequestLog` already records the endpoint that answered it, so *"has anything actually
/// called this endpoint?"* has always been answerable — there was simply nothing to ask. Answering it
/// beside the endpoint turns a three-step detour (read the endpoint, open the request log, filter by
/// hand) into a glance.
///
/// **The panel that used to render these is gone.** `EndpointTrafficList` was 398 lines showing the
/// same rows the request log already shows, in a 320pt column, and the inspector's three-mode rail has
/// no room for a fourth item — it measures ~282pt against a 260pt floor as it is. So the *answer*
/// survives and the second list does not: the inspector shows a count, and clicking it scopes the
/// request log to this endpoint. Same question, one panel instead of two, and the rows are in the
/// place the user was already watching.
///
/// The scoping itself is `RequestLogFilter.endpointID`, in Domain — so the CLI can ask the same
/// question the window does.
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

