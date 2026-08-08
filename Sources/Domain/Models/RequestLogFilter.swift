import Foundation

/// Which logged requests a caller wants to see.
///
/// **This exists because the predicate was already written twice and agreed only by coincidence.**
/// `RequestLogQuery.process` filtered the drawer's rows, and `AppControlHost` re-implemented the same
/// `unmatchedOnly` rule for the `logList` command — two copies of "what counts as unmatched", in two
/// modules, with nothing tracking that they matched. The redesign then proposed adding a third filter
/// (`journeyOnly`) to both, which would have made three.
///
/// So the rule moves to Domain, where `AGENTS.md` says every rule that is a function of state belongs:
/// the window and the script now answer the same question the same way, and a filter added here is
/// available to both without either being edited.
///
/// `Sendable` and free of any view or store type, so the CLI can build one and a test can exercise it
/// as a value.
public struct RequestLogFilter: Equatable, Sendable {
    /// Only calls nothing answered — the fastest way to find a missing configuration, and the reason
    /// this is a toggle rather than a search term.
    public var unmatchedOnly: Bool
    /// Only calls a journey answered. Note this is **not** the complement of `unmatchedOnly`: a call
    /// blocked by an active journey is neither unmatched nor served by one.
    public var journeyOnly: Bool
    /// Restrict to a single HTTP method.
    public var method: HTTPMethod?
    /// Restrict to one endpoint's traffic — what the inspector's endpoint count jumps into.
    public var endpointID: UUID?
    /// Free text, matched case-insensitively against the path, the status code and the outcome label.
    public var text: String

    public init(
        unmatchedOnly: Bool = false,
        journeyOnly: Bool = false,
        method: HTTPMethod? = nil,
        endpointID: UUID? = nil,
        text: String = ""
    ) {
        self.unmatchedOnly = unmatchedOnly
        self.journeyOnly = journeyOnly
        self.method = method
        self.endpointID = endpointID
        self.text = text
    }

    /// Nothing filtered — every logged request.
    public static let none = RequestLogFilter()

    /// Whether this filter would remove anything at all.
    ///
    /// Worth having as a property rather than as a check at each call site: a log header decides
    /// whether to offer a "clear filters" affordance from exactly this question, and the empty state
    /// needs it to tell "no requests yet" apart from "no requests *match*" — which are different
    /// sentences and were being chosen by four separate conditions.
    public var isActive: Bool {
        unmatchedOnly || journeyOnly || method != nil || endpointID != nil || !text.isEmpty
    }

    /// Does this entry survive the filter?
    public func matches(_ log: RequestLog) -> Bool {
        if unmatchedOnly, !log.outcome.isMissingConfiguration { return false }
        if journeyOnly, log.matchedJourneyID == nil { return false }
        if let method, log.method != method { return false }
        if let endpointID, log.matchedEndpointID != endpointID { return false }

        guard !text.isEmpty else { return true }

        // Case-insensitive across the three fields a reader actually scans. Deliberately *not* the
        // request or response body: the field's placeholder has never promised body search, and
        // scanning a 20KB payload per keystroke on every row is not a filter, it is a stall.
        let query = text.lowercased()
        if log.path.lowercased().contains(query) { return true }
        if let code = log.responseStatusCode, "\(code)".contains(query) { return true }
        if log.outcome.label.lowercased().contains(query) { return true }
        return false
    }

    /// Apply to a collection, preserving order.
    public func apply(to logs: [RequestLog]) -> [RequestLog] {
        guard isActive else { return logs }
        return logs.filter(matches)
    }
}
