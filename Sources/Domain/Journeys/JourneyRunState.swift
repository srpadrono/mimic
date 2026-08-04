import Foundation

/// Where a journey run currently stands: how many times each step has answered, which step is
/// next, and whether the script has finished.
///
/// This is a value type on purpose. The engine holds exactly one of these and replaces it wholesale
/// after each request, so "what will the next request return?" is a pure function of
/// `(request, journey, state)` — which is what makes journeys reproducible and unit-testable
/// without a server.
///
/// The cursor is always normalized to **the first step that is not yet exhausted**. Steps are keyed
/// by id rather than index so editing a journey mid-run degrades gracefully instead of silently
/// replaying the wrong step.
public struct JourneyRunState: Codable, Sendable, Equatable {
    public let journeyID: UUID
    /// Index of the first unexhausted step, or `steps.count` when the journey is finished.
    public private(set) var cursor: Int
    /// Times each step has answered, keyed by step id (`uuidString` keeps the JSON readable).
    public private(set) var servedCountsByStepID: [String: Int]
    /// Steps retired by an explicit advance rather than by exhausting their `repeatCount`.
    public private(set) var forceAdvancedStepIDs: Set<String>
    public private(set) var isComplete: Bool
    /// Total steps served across the run, including replays after a `.restart` completion.
    public private(set) var totalServed: Int

    public init(journeyID: UUID) {
        self.journeyID = journeyID
        cursor = 0
        servedCountsByStepID = [:]
        forceAdvancedStepIDs = []
        isComplete = false
        totalServed = 0
    }

    /// Full initializer — used by persistence/tests to rehydrate a partially-run journey.
    public init(
        journeyID: UUID,
        cursor: Int,
        servedCountsByStepID: [String: Int],
        forceAdvancedStepIDs: Set<String>,
        isComplete: Bool,
        totalServed: Int
    ) {
        self.journeyID = journeyID
        self.cursor = cursor
        self.servedCountsByStepID = servedCountsByStepID
        self.forceAdvancedStepIDs = forceAdvancedStepIDs
        self.isComplete = isComplete
        self.totalServed = totalServed
    }

    // MARK: - Queries

    public func servedCount(forStepID id: UUID) -> Int {
        servedCountsByStepID[id.uuidString] ?? 0
    }

    /// A step is exhausted once it has answered `repeatCount` times — or immediately, if it was
    /// retired by an explicit advance. When `autoAdvance` is off a step never exhausts on its own,
    /// so it keeps answering until something advances the journey.
    public func isExhausted(_ step: JourneyStep, autoAdvance: Bool) -> Bool {
        if forceAdvancedStepIDs.contains(step.id.uuidString) { return true }
        guard autoAdvance else { return false }
        return servedCount(forStepID: step.id) >= step.repeatCount
    }

    public func currentStep(in journey: Journey) -> JourneyStep? {
        guard !isComplete, cursor >= 0, cursor < journey.steps.count else { return nil }
        return journey.steps[cursor]
    }

    // MARK: - Transitions

    /// Records that `step` answered a request and re-normalizes the cursor.
    ///
    /// Completion is handled here rather than by the caller so `.restart` journeys loop without any
    /// coordination: the state simply comes back as a fresh run.
    public func recordingServe(of step: JourneyStep, in journey: Journey) -> JourneyRunState {
        var updated = self
        let key = step.id.uuidString
        updated.servedCountsByStepID[key] = (updated.servedCountsByStepID[key] ?? 0) + 1
        updated.totalServed += 1
        return updated.normalized(in: journey)
    }

    /// Retires the step at the cursor without serving it — the manual "move on" control.
    /// Returns `self` unchanged when the journey is already complete or has no steps.
    public func advancing(in journey: Journey) -> JourneyRunState {
        guard let step = currentStep(in: journey) else { return self }
        var updated = self
        updated.forceAdvancedStepIDs.insert(step.id.uuidString)
        return updated.normalized(in: journey)
    }

    /// Restarts the run from step one, preserving nothing but the journey identity.
    public func restarted() -> JourneyRunState {
        JourneyRunState(journeyID: journeyID)
    }

    /// Moves the cursor to the first unexhausted step and applies the completion behavior.
    private func normalized(in journey: Journey) -> JourneyRunState {
        var updated = self
        var index = 0
        while index < journey.steps.count,
              updated.isExhausted(journey.steps[index], autoAdvance: journey.autoAdvance) {
            index += 1
        }
        updated.cursor = index

        guard index >= journey.steps.count else {
            updated.isComplete = false
            return updated
        }

        switch journey.completion {
        case .stop:
            updated.isComplete = true
            return updated
        case .restart:
            // Loop: keep the lifetime `totalServed` so callers can still see how much traffic the
            // journey has answered, but hand back an otherwise-fresh run.
            var looped = JourneyRunState(journeyID: journeyID)
            looped.totalServed = updated.totalServed
            return looped
        }
    }
}

// MARK: - Reporting

/// A snapshot of run progress shaped for CLI/UI consumption — the answer to
/// "where is this journey right now, and what happens next?".
public struct JourneyStatus: Codable, Sendable, Equatable {
    public let journeyID: UUID
    public let journeyName: String
    public let isComplete: Bool
    public let totalSteps: Int
    public let totalServed: Int
    public let currentStepIndex: Int?
    public let steps: [JourneyStepProgress]

    public init(
        journeyID: UUID,
        journeyName: String,
        isComplete: Bool,
        totalSteps: Int,
        totalServed: Int,
        currentStepIndex: Int?,
        steps: [JourneyStepProgress]
    ) {
        self.journeyID = journeyID
        self.journeyName = journeyName
        self.isComplete = isComplete
        self.totalSteps = totalSteps
        self.totalServed = totalServed
        self.currentStepIndex = currentStepIndex
        self.steps = steps
    }

    /// Builds the report for a journey and its run state. `state` may belong to a different journey
    /// (or be absent) — in that case the report shows a not-yet-started run.
    public static func make(journey: Journey, state: JourneyRunState?) -> JourneyStatus {
        let runState = (state?.journeyID == journey.id ? state : nil) ?? JourneyRunState(journeyID: journey.id)
        let steps = journey.steps.enumerated().map { index, step in
            JourneyStepProgress(
                id: step.id,
                index: index,
                name: step.name,
                method: step.method,
                path: step.path,
                graphqlOperation: step.graphqlOperation,
                statusCode: step.outcome.observedStatusCode,
                failure: JourneyStepProgress.failureLabel(for: step.outcome),
                repeatCount: step.repeatCount,
                servedCount: runState.servedCount(forStepID: step.id),
                isExhausted: runState.isExhausted(step, autoAdvance: journey.autoAdvance),
                isCurrent: !runState.isComplete && runState.cursor == index
            )
        }
        return JourneyStatus(
            journeyID: journey.id,
            journeyName: journey.name,
            isComplete: runState.isComplete,
            totalSteps: journey.steps.count,
            totalServed: runState.totalServed,
            currentStepIndex: runState.isComplete || runState.cursor >= journey.steps.count ? nil : runState.cursor,
            steps: steps
        )
    }
}

public struct JourneyStepProgress: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let index: Int
    public let name: String
    public let method: HTTPMethod
    public let path: String
    /// The GraphQL operation this step matches, when it has one.
    public let graphqlOperation: String?
    public let statusCode: Int?
    public let failure: String?
    public let repeatCount: Int
    public let servedCount: Int
    public let isExhausted: Bool
    public let isCurrent: Bool

    public init(
        id: UUID,
        index: Int,
        name: String,
        method: HTTPMethod,
        path: String,
        graphqlOperation: String? = nil,
        statusCode: Int?,
        failure: String?,
        repeatCount: Int,
        servedCount: Int,
        isExhausted: Bool,
        isCurrent: Bool
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.method = method
        self.path = path
        self.graphqlOperation = graphqlOperation
        self.statusCode = statusCode
        self.failure = failure
        self.repeatCount = repeatCount
        self.servedCount = servedCount
        self.isExhausted = isExhausted
        self.isCurrent = isCurrent
    }

    static func failureLabel(for outcome: JourneyStepOutcome) -> String? {
        switch outcome {
        case .respond: nil
        case let .networkFailure(failure):
            switch failure {
            case .connectionDrop: "connection-drop"
            case let .timeout(holdMs): "timeout(\(holdMs)ms)"
            }
        }
    }
}
