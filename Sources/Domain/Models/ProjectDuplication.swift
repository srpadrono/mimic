import Foundation

/// Copying a whole project, with every identifier reminted.
///
/// A `MockProject` is a tree, and only its root was ever being copied. Both hosts duplicated one by
/// constructing `MockProject(name: "… (Copy)", endpoints: source.endpoints, …)` — a fresh project id
/// wrapped around the *source's* endpoints, scenarios, journeys and steps, ids and all.
///
/// The schema does not allow that. `endpoint.id`, `scenario.id`, `journey.id` and `journeyStep.id`
/// are each a `PRIMARY KEY` on their own table, unique across the database rather than scoped to a
/// project, and `GRDBProjectRepository.save` deletes children by the *incoming* project's id — which
/// matches nothing for a project that does not exist yet — and then inserts. So the first row it
/// wrote collided with the original, GRDB's default conflict policy aborted, and the whole
/// `dbQueue.write` rolled back. Duplicating a project created nothing.
///
/// It failed silently in both directions, which is why it survived. The window swallows the throw
/// (`ProjectWorkspace.duplicateProject`'s `catch` treats it as non-critical), and the window's control
/// host answers `mimic project duplicate` with a success envelope *before* the store is touched, so
/// the CLI exits 0. Only a project with no endpoints and no journeys ever worked — which is exactly
/// what both tests of it construct.
///
/// The rule this needed already existed twenty lines from where it was needed: the duplication
/// helpers in ``ProjectCommandExecutor`` remint scenario and step ids, under a comment explaining
/// that sharing them lets an edit to the copy mutate the original. Those apply to duplicating one
/// endpoint or one journey *inside* a project. This is the same rule at the level above, and it lives
/// in Domain for the same reason everything else does: it was written twice outside the executor, and
/// both copies were wrong.
extension MockProject {

    /// A copy of this project under `name`, sharing no identifier with it.
    ///
    /// Names, paths, responses and settings are preserved exactly — this is a copy, not a rename.
    /// Only identity is new, and the two references that point *into* the tree (an endpoint's active
    /// scenario, the project's active journey) are repointed at their counterparts in the copy rather
    /// than left dangling at the original's.
    public func duplicated(name: String) -> MockProject {
        var journeyIdentifiers: [UUID: UUID] = [:]
        let copiedJourneys = journeys.map { source -> Journey in
            let copy = source.copyingWithFreshIdentifiers()
            journeyIdentifiers[source.id] = copy.id
            return copy
        }

        return MockProject(
            name: name,
            serverConfiguration: serverConfiguration,
            endpoints: endpoints.map { $0.copyingWithFreshIdentifiers() },
            journeys: copiedJourneys,
            // Remapped, not carried over: the source's id names a journey that belongs to the source.
            // `activeJourney` resolves a dangling id to `nil`, so carrying it would have quietly
            // deactivated the journey in the copy.
            activeJourneyID: activeJourneyID.flatMap { journeyIdentifiers[$0] }
        )
    }
}

extension Endpoint {

    /// This endpoint with a new id and new scenario ids, keeping which scenario is active.
    ///
    /// The active scenario is followed by *position* rather than by id, because the ids are precisely
    /// what is changing. Falling back to the first scenario matches what endpoint creation does: an
    /// endpoint with responses and no active one silently 404s, which is never what a copy should be.
    public func copyingWithFreshIdentifiers() -> Endpoint {
        let activeIndex = activeScenarioID.flatMap { active in
            scenarios.firstIndex { $0.id == active }
        }
        let copiedScenarios = scenarios.map { source in
            Scenario(
                name: source.name,
                statusCode: source.statusCode,
                headers: source.headers,
                body: source.body,
                bodyContentType: source.bodyContentType
            )
        }

        return Endpoint(
            name: name,
            method: method,
            path: path,
            scenarios: copiedScenarios,
            activeScenarioID: activeIndex.map { copiedScenarios[$0].id } ?? copiedScenarios.first?.id,
            delayMs: delayMs,
            groupTag: groupTag,
            graphqlOperation: graphqlOperation
        )
    }
}

extension Journey {

    /// This journey with a new id and new step ids, in the same order.
    public func copyingWithFreshIdentifiers() -> Journey {
        Journey(
            name: name,
            summary: summary,
            steps: steps.map { source in
                JourneyStep(
                    name: source.name,
                    method: source.method,
                    path: source.path,
                    outcome: source.outcome,
                    delayMs: source.delayMs,
                    repeatCount: source.repeatCount,
                    graphqlOperation: source.graphqlOperation
                )
            },
            matchMode: matchMode,
            completion: completion,
            unmatchedBehavior: unmatchedBehavior,
            autoAdvance: autoAdvance
        )
    }
}
