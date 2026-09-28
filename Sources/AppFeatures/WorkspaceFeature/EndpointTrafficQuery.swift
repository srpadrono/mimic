import Foundation
import Domain

/// The question the endpoint inspector's Traffic section asks of the request log, kept out of the
/// view so it can be tested without rendering anything.
///
/// Every `RequestLog` already records the endpoint that answered it, so *"has anything actually
/// called this endpoint?"* is answerable beside the endpoint instead of by filtering the request log
/// by hand.
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
}
