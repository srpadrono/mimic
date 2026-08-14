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

    /// High-water mark of the activation epochs pushes have carried. See
    /// ``update(endpoints:globalDelayMs:journey:activationEpoch:)``.
    private var observedActivationEpoch = 0

    func update(endpoints: [Endpoint], globalDelayMs: Int) {
        self.endpoints = endpoints
        self.globalDelayMs = globalDelayMs
    }

    /// Replaces the whole live configuration.
    ///
    /// Three different events arrive here through this one call, and only two of them are visible in
    /// the arguments:
    ///
    /// - **A different journey, or the same journey with edited steps.** Visible: the run is reset
    ///   from the arguments themselves, because a cursor into a sequence that no longer exists is
    ///   worse than starting over — a test would silently exercise the wrong step.
    /// - **A re-push of the project that is already loaded**, which every other mutation of the open
    ///   document causes. Also visible, by the same comparison coming out equal, and it must leave a
    ///   run in progress alone. That is the whole reason the comparison exists.
    /// - **An activation.** *Not* visible when the journey being activated is the one already
    ///   active: `journey` is the same value and the endpoints are the same, so re-activating is
    ///   argument-for-argument identical to the re-push above. Only the caller knows which of the
    ///   two happened, and `activationEpoch` is how it says so — a count of the activations the
    ///   session has performed, read at push time. A push carrying an epoch higher than any seen
    ///   before *is* an activation, and resets the run even though nothing else changed.
    ///
    /// A count rather than a flag, because the push is not issued by the activation. In the window,
    /// `AppState.activateJourney` writes `activeJourneyID` and the push goes out afterwards from
    /// `ProjectWorkspace.currentProject`'s `didSet`, which every project mutation shares; a flag
    /// would have to be remembered across that gap and cleared on the far side, while a count is
    /// simply read by whatever push happens to go out next and stays correct if several do.
    ///
    /// Compared with `>` against a high-water mark rather than with `!=`, because this actor cannot
    /// assume its callers serialize. `MockServerRuntime.updateMocks` chains its pushes, so the
    /// production sequence arrives in dispatch order — but that is the caller's discipline, not this
    /// API's contract: `updateConfiguration` is public, and a push reaching this actor from an
    /// unstructured task can still land after a newer one. A late push carrying an older epoch must
    /// not rewind a run a newer one has already started, and must not lower the mark.
    ///
    /// `activationEpoch: nil` means the caller did not say, and is treated as a re-push — which is
    /// what the three-argument overload on `MockServerEngine` passes.
    func update(
        endpoints: [Endpoint],
        globalDelayMs: Int,
        journey: Journey?,
        activationEpoch: Int?
    ) {
        self.endpoints = endpoints
        self.globalDelayMs = globalDelayMs

        var isActivation = false
        if let activationEpoch, activationEpoch > observedActivationEpoch {
            observedActivationEpoch = activationEpoch
            isActivation = true
        }

        let previous = self.journey
        self.journey = journey

        guard let journey else {
            runState = nil
            return
        }
        let journeyChanged = previous?.id != journey.id || previous?.steps != journey.steps
        let runBelongsElsewhere = runState?.journeyID != journey.id
        if isActivation || journeyChanged || runBelongsElsewhere {
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
