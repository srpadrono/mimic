import Foundation

/// What a journey decided about one request.
public enum JourneyOutcome: Sendable, Equatable {
    /// The journey scripted this request. Carries the response to serve and the advanced run state.
    case served(response: ResolvedResponse, state: JourneyRunState, step: JourneyStep, stepIndex: Int)
    /// No step applies — resolve the request against the project's endpoints instead.
    case fallThrough(state: JourneyRunState)
    /// No step applies and the journey says unscripted calls must fail.
    case blocked(state: JourneyRunState)
}

/// Pure journey resolution: given a request, a journey, and where the run stands, decide what to
/// serve and where the run stands next.
///
/// Keeping this out of the engine is what makes a journey testable as a table of
/// `(requests in) -> (responses out)` with no sockets involved — and it is why the same rules apply
/// identically whether the request arrives over HTTP or is replayed by the CLI.
public enum JourneyResolver {
    public static func resolve(
        request: IncomingRequest,
        journey: Journey,
        state: JourneyRunState,
        globalDelayMs: Int
    ) -> JourneyOutcome {
        var operationLookup = RequestOperationLookup(request: request)
        return resolve(
            request: request, journey: journey, state: state,
            globalDelayMs: globalDelayMs, operationLookup: &operationLookup
        )
    }

    static func resolve(
        request: IncomingRequest,
        journey: Journey,
        state: JourneyRunState,
        globalDelayMs: Int,
        operationLookup: inout RequestOperationLookup
    ) -> JourneyOutcome {
        // A state left over from a previous journey must not leak progress into this one.
        let runState = state.journeyID == journey.id ? state : JourneyRunState(journeyID: journey.id)

        guard !runState.isComplete, !journey.steps.isEmpty else {
            return unmatched(journey: journey, state: runState)
        }

        guard let hit = matchingStep(
            request: request, journey: journey, state: runState, operationLookup: &operationLookup
        ) else {
            return unmatched(journey: journey, state: runState)
        }

        let step = journey.steps[hit]
        return .served(
            response: response(for: step, journey: journey, globalDelayMs: globalDelayMs),
            state: runState.recordingServe(of: step, in: journey),
            step: step,
            stepIndex: hit
        )
    }

    /// The index of the step that answers this request, or `nil` if none does.
    ///
    /// `strictSequence` looks only at the cursor; `orderedPerEndpoint` scans forward for the first
    /// unexhausted step that matches, which lets steps for *other* routes stay pending while this
    /// route advances. Both start at the cursor, so a step is never replayed once retired.
    private static func matchingStep(
        request: IncomingRequest,
        journey: Journey,
        state: JourneyRunState,
        operationLookup: inout RequestOperationLookup
    ) -> Int? {
        // A negative cursor names no step, and both branches below would subscript with it:
        // `strictSequence` builds `-1..<0`, `orderedPerEndpoint` builds `-1..<count`, and each then
        // reads `journey.steps[-1]`. `JourneyRunState`'s full initializer now clamps this at zero,
        // and that is not a reason to drop the guard here — the initializer is only *one* of the two
        // ways a value of that type comes into being. The other is `Codable`: the type declares no
        // `init(from:)`, so the synthesized one assigns the stored properties directly and never
        // runs the clamp. A persisted or hand-written `{"cursor":-1}` therefore arrives here exactly
        // as it was written. Clamp where the value is constructed, guard where it is used as an
        // index; neither alone covers both doors.
        guard state.cursor >= 0 else { return nil }

        let searchRange: Range<Int>
        switch journey.matchMode {
        case .strictSequence:
            guard state.cursor < journey.steps.count else { return nil }
            searchRange = state.cursor..<(state.cursor + 1)
        case .orderedPerEndpoint:
            // Clamped, because `a..<b` with `a > b` is not an empty range — it is a precondition
            // failure, and this runs inside the embedded server, so the trap takes the whole app
            // down with it. `strictSequence` guards the same condition one line up; this branch did
            // not, and it is the default mode. A cursor past the end is reachable whenever a journey
            // is rehydrated against steps that have since been removed — `JourneyRunState`'s public
            // initializer exists for exactly that, and promises the run "degrades gracefully instead
            // of silently replaying the wrong step". Nothing here was keeping that promise.
            searchRange = min(state.cursor, journey.steps.count)..<journey.steps.count
        }

        for index in searchRange {
            let step = journey.steps[index]
            guard !state.isExhausted(step, autoAdvance: journey.autoAdvance) else { continue }
            guard step.method == request.method else { continue }
            guard step.backendID == request.backendID else { continue }
            guard PathPattern.matches(requestPath: request.path, pattern: step.path) else { continue }
            // A step naming an operation answers only that operation, so a GraphQL flow can script
            // several calls that are otherwise identical.
            guard operationLookup.specificity(declared: step.graphqlOperation) != nil
            else { continue }
            return index
        }
        return nil
    }

    private static func unmatched(journey: Journey, state: JourneyRunState) -> JourneyOutcome {
        switch journey.unmatchedBehavior {
        case .fallThroughToEndpoints: .fallThrough(state: state)
        case .notFound: .blocked(state: state)
        }
    }

    private static func response(
        for step: JourneyStep,
        journey: Journey,
        globalDelayMs: Int
    ) -> ResolvedResponse {
        let delayMs = ResponseDelay.combined(globalMs: globalDelayMs, localMs: step.delayMs)

        switch step.outcome {
        case let .respond(scripted):
            return ResolvedResponse(
                statusCode: scripted.statusCode,
                headers: scripted.headers,
                contentType: scripted.contentType,
                body: scripted.body,
                delayMs: delayMs,
                matchedEndpointID: nil,
                matchedScenarioID: nil,
                failure: nil,
                matchedJourneyID: journey.id,
                matchedJourneyStepID: step.id,
                outcome: .journey
            )
        case let .networkFailure(failure):
            return ResolvedResponse(
                // Never written — the connection is aborted — but recorded so the request log can
                // show *something* meaningful for a failed step.
                statusCode: 0,
                headers: [:],
                contentType: .plainText,
                body: nil,
                delayMs: delayMs,
                matchedEndpointID: nil,
                matchedScenarioID: nil,
                failure: failure,
                matchedJourneyID: journey.id,
                matchedJourneyStepID: step.id,
                outcome: .journey
            )
        }
    }
}

/// Path matching shared by endpoints and journey steps: `/` separated segments where a `:name`
/// segment matches anything. Returns the number of literal segments matched so callers can rank
/// competing patterns by specificity.
public enum PathPattern {
    /// Identity for patterns that match the same paths with the same specificity. Empty slash
    /// segments and wildcard names do not affect matching. Literal Unicode and its UTF-8 URL
    /// encoding share an identity; encoded reserved characters retain their meaning as data.
    public static func matchingKey(for pattern: String) -> [String] {
        segments(in: pattern.utf8).map { $0.hasPrefix(":") ? ":" : literalKey($0) }
    }

    public static func specificity(requestPath: String, pattern: String) -> Int? {
        // Query strings never participate in matching.
        let requestSegments = segments(in: requestPath.utf8.prefix { $0 != 0x3F })
        let patternSegments = segments(in: pattern.utf8)
        guard requestSegments.count == patternSegments.count else { return nil }

        var literalMatches = 0
        for (requestSegment, patternSegment) in zip(requestSegments, patternSegments) {
            if patternSegment.hasPrefix(":") { continue }
            if literalKey(requestSegment) != literalKey(patternSegment) { return nil }
            literalMatches += 1
        }
        return literalMatches
    }

    public static func matches(requestPath: String, pattern: String) -> Bool {
        specificity(requestPath: requestPath, pattern: pattern) != nil
    }

    /// ASCII URL delimiters remain delimiters even beside a Unicode combining mark.
    private static func segments<C: Collection>(in bytes: C) -> [String] where C.Element == UInt8 {
        bytes.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
    }

    /// URL clients encode Unicode and characters outside RFC 3986's pchar grammar. Normalize each
    /// literal segment the same way, after splitting, so `%2F` can never create another segment and
    /// `%3A` can never become a wildcard. Existing escapes are retained, with uppercase hex digits.
    private static func literalKey<S: StringProtocol>(_ segment: S) -> String {
        let input = Array(segment.utf8)
        let hex = Array("0123456789ABCDEF".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0x25, index + 2 < input.count,
               let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                output += [0x25, hex[Int(high)], hex[Int(low)]]
                index += 3
                continue
            }
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
                 0x2D, 0x2E, 0x5F, 0x7E, // unreserved
                 0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D, 0x3A, 0x40:
                output.append(byte)
            default:
                output += [0x25, hex[Int(byte >> 4)], hex[Int(byte & 0xF)]]
            }
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
