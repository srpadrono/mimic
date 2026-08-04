import Foundation

/// What actually answered a request.
///
/// This exists because "no endpoint matched" used to be *inferred* from a nil `matchedEndpointID` —
/// and once journeys arrived that inference broke: a journey step answers without a matched endpoint
/// too, so both cases rendered as an em dash and a request with no configuration became
/// indistinguishable from one that was handled perfectly.
///
/// Naming the outcome rather than deducing it makes the most valuable line in the request log —
/// *"nothing here is configured for this call"* — something the UI and the CLI can both point at.
public enum RequestOutcome: String, Codable, Sendable, CaseIterable {
    /// An endpoint's active scenario answered.
    case endpoint

    /// A journey step answered.
    case journey

    /// Nothing matched. The caller is missing a mock — this is the case worth surfacing loudly.
    case unmatched

    /// A journey is active with `unmatchedBehavior == .notFound` and refused an unscripted request.
    /// Distinct from ``unmatched``: the configuration is deliberate, not missing.
    case blockedByJourney

    /// Whether this outcome means Mimic had nothing configured for the request.
    public var isMissingConfiguration: Bool {
        self == .unmatched
    }

    /// Short label for tables and CLI output.
    public var label: String {
        switch self {
        case .endpoint: "Endpoint"
        case .journey: "Journey"
        case .unmatched: "Unmatched"
        case .blockedByJourney: "Blocked"
        }
    }
}
