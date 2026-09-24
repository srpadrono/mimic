import Foundation

/// The single place a request becomes a response.
///
/// Resolution is layered: an active journey gets first refusal, and whatever it declines falls
/// through to normal endpoint matching. Composing the two here — rather than in the Vapor handler —
/// keeps "what will Mimic return for this request?" a pure function that tests can call directly,
/// and guarantees the CLI's journey preview and the live server agree by construction.
public enum MockResolver {
    /// A resolved request plus the journey state it produced.
    public struct Plan: Sendable, Equatable {
        public let response: ResolvedResponse
        /// The run state to store after this request. `nil` when no journey is active.
        public let journeyState: JourneyRunState?

        public init(response: ResolvedResponse, journeyState: JourneyRunState?) {
            self.response = response
            self.journeyState = journeyState
        }
    }

    public static func plan(
        request: IncomingRequest,
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey? = nil,
        journeyState: JourneyRunState? = nil
    ) -> Plan {
        var operationLookup = RequestOperationLookup(request: request)
        return plan(
            request: request, endpoints: endpoints, globalDelayMs: globalDelayMs,
            journey: journey, journeyState: journeyState, operationLookup: &operationLookup
        )
    }

    static func plan(
        request: IncomingRequest,
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?,
        journeyState: JourneyRunState?,
        operationLookup: inout RequestOperationLookup
    ) -> Plan {
        guard let journey else {
            return Plan(
                response: RequestMatcher.resolve(
                    request: request,
                    against: endpoints,
                    globalDelayMs: globalDelayMs,
                    operationLookup: &operationLookup
                ),
                journeyState: nil
            )
        }

        let state = journeyState?.journeyID == journey.id
            ? (journeyState ?? JourneyRunState(journeyID: journey.id))
            : JourneyRunState(journeyID: journey.id)

        switch JourneyResolver.resolve(
            request: request,
            journey: journey,
            state: state,
            globalDelayMs: globalDelayMs,
            operationLookup: &operationLookup
        ) {
        case let .served(response, nextState, _, _):
            return Plan(response: response, journeyState: nextState)

        case let .fallThrough(nextState):
            return Plan(
                response: RequestMatcher.resolve(
                    request: request,
                    against: endpoints,
                    globalDelayMs: globalDelayMs,
                    operationLookup: &operationLookup
                ),
                journeyState: nextState
            )

        case let .blocked(nextState):
            return Plan(response: .journeyBlocked, journeyState: nextState)
        }
    }
}
