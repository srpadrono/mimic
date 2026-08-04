import Domain

/// Thread-safe holder for the live mock configuration, including the active journey and where its
/// run currently stands.
///
/// Being an actor is what makes journeys correct under concurrency: `resolve` reads the cursor,
/// picks a step, and writes the advanced cursor back in one non-reentrant step. Two simultaneous
/// requests therefore cannot consume the same step, which is the failure mode a naive
/// read-then-write would have. Matching and delay arithmetic stay in Domain — this actor only owns
/// the snapshot and the cursor.
actor MockRouteStore {
    private var endpoints: [Endpoint] = []
    private var globalDelayMs: Int = 0
    private var journey: Journey?
    private var runState: JourneyRunState?

    func update(endpoints: [Endpoint], globalDelayMs: Int) {
        self.endpoints = endpoints
        self.globalDelayMs = globalDelayMs
    }

    /// Replaces the whole live configuration.
    ///
    /// The run state is preserved only when the *same* journey is still active and its steps are
    /// unchanged. Editing a journey mid-run resets it, because a cursor into a sequence that no
    /// longer exists is worse than starting over — a test would silently exercise the wrong step.
    func update(endpoints: [Endpoint], globalDelayMs: Int, journey: Journey?) {
        self.endpoints = endpoints
        self.globalDelayMs = globalDelayMs

        let previous = self.journey
        self.journey = journey

        guard let journey else {
            runState = nil
            return
        }
        if previous?.id != journey.id || previous?.steps != journey.steps {
            runState = JourneyRunState(journeyID: journey.id)
        } else if runState?.journeyID != journey.id {
            runState = JourneyRunState(journeyID: journey.id)
        }
    }

    func resolve(request: IncomingRequest) -> ResolvedResponse {
        let plan = MockResolver.plan(
            request: request,
            endpoints: endpoints,
            globalDelayMs: globalDelayMs,
            journey: journey,
            journeyState: runState
        )
        if let nextState = plan.journeyState {
            runState = nextState
        }
        return plan.response
    }

    // MARK: Journey runtime control

    func restartJourney() -> JourneyStatus? {
        guard let journey else { return nil }
        runState = JourneyRunState(journeyID: journey.id)
        return JourneyStatus.make(journey: journey, state: runState)
    }

    func advanceJourney() -> JourneyStatus? {
        guard let journey else { return nil }
        let current = runState ?? JourneyRunState(journeyID: journey.id)
        runState = current.advancing(in: journey)
        return JourneyStatus.make(journey: journey, state: runState)
    }

    func journeyStatus() -> JourneyStatus? {
        guard let journey else { return nil }
        return JourneyStatus.make(journey: journey, state: runState)
    }
}
