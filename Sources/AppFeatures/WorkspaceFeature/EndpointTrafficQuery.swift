import Foundation
import Domain

/// The one question the request log answers about a single endpoint: *has anything called it?*
///
/// Every `RequestLog` already records the endpoint that answered it, so this has always been
/// answerable — there was simply nothing to ask. Answering it beside the endpoint turns a three-step
/// detour (read the endpoint, open the request log, filter by hand) into a glance.
///
/// **This used to be a whole panel.** `EndpointTrafficList` was 398 lines showing the same rows the
/// request log already shows, in a 320pt column, and the inspector's three-mode rail has no room for
/// a fourth item — it measures ~282pt against a 260pt floor as it is. So the *answer* survives and
/// the second list does not: the inspector shows a count, and clicking it scopes the request log to
/// this endpoint. Same question, one panel instead of two, and the rows are in the place the user was
/// already watching.
///
/// Three sibling helpers died with that panel and are not coming back. `logs(forEndpoint:in:)`
/// returned the matching entries newest-first; `summary(for:)` wrote *"12 requests · 2 failed"*; and
/// `statusBreakdown(for:)` counted status codes for a distribution row. None had a production caller
/// after the panel was retired — only tests, which is how dead code survives an audit that greps for
/// callers. `logs` was the expensive one, and it was being called for its `.count`: the array it
/// built was filtered, **sorted**, and re-materialised on every body evaluation, then discarded
/// unread. On a busy server that is an O(n log n) sort per served request for a single integer.
///
/// The scoping itself is `RequestLogFilter.endpointID`, in Domain. **The CLI cannot reach it yet** —
/// `mimic log list` exposes `--unmatched` and `--journey-only` but no `--endpoint-id`, so this is one
/// of the few filters the window has and a script does not. Recorded as a known gap in
/// `docs/ROADMAP.md`; the field is already in the right module for the flag to be a small addition.
enum EndpointTrafficQuery {
    /// How many requests this endpoint answered.
    ///
    /// Requests that matched a *different* endpoint are excluded, and so are the ones that matched no
    /// endpoint at all — an unmatched call and a journey-answered call both carry a nil
    /// `matchedEndpointID`, and neither belongs to this endpoint's history.
    ///
    /// `count(where:)` rather than `filter { }.count`: this runs inside `WorkspaceView.body`, which
    /// re-evaluates on every served request, and the filtering form would allocate an array per
    /// request to ask for its length.
    nonisolated static func count(forEndpoint endpointID: UUID, in logs: [RequestLog]) -> Int {
        logs.count { $0.matchedEndpointID == endpointID }
    }
}
