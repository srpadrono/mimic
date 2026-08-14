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
/// It failed silently in both directions, which is why it survived. The window swallowed the throw
/// (`ProjectWorkspace.duplicateProject`'s `catch` treated it as non-critical; it reports on
/// `autosaveStatus` now), and the window's control host answers `mimic project duplicate` with a
/// success envelope *before* the store is touched, so the CLI exits 0. Only a project with no endpoints and no journeys ever worked — which is exactly
/// what both tests of it construct.
///
/// The rule this needed already existed twenty lines from where it was needed: the duplication
/// helpers in ``ProjectCommandExecutor`` reminted scenario and step ids, because sharing them lets an
/// edit to the copy mutate the original — the reason now recorded on
/// ``Scenario/copyingWithFreshIdentifiers()``, which is where that reminting moved. Those apply to
/// duplicating one endpoint or one journey *inside* a project. This is the same rule at the level
/// above, and it lives in Domain for the same reason everything else does: it was written twice
/// outside the executor, and both copies were wrong.
///
/// ## These helpers are the only implementation
///
/// `ProjectCommandExecutor.duplicate` calls into them rather than building its own copy. It used to
/// build one, and the two disagreed: the executor pointed every copy at `scenarios.first`, while the
/// helper below follows the source's *active* scenario by position. So `mimic endpoint duplicate` and
/// `mimic project duplicate` produced different copies of the same endpoint whenever its active
/// scenario was not its first — the duplicate answered with a response the original does not serve.
///
/// ## Each helper enumerates its model's stored properties by hand
///
/// The structurally complete form — `var copy = self; copy.id = UUID()`, which cannot drop a field
/// because it never names one — is unavailable: `id` is a `let` on ``MockProject``, ``Endpoint``,
/// ``Scenario``, ``Journey`` and ``JourneyStep``, so no copy can remint one in place. Widening those
/// five to `var` would buy the safer copy, and it is a trade for a human to make rather than a
/// cleanup: it gives up an identity that cannot change under a holder in exchange for a duplication
/// that cannot silently drop a field.
///
/// Until then each helper below states the field list it must track, and adding a property to one of
/// those models means coming back here. What has changed is what happens if you do not:
/// `Tests/DomainTests/DuplicationCompletenessTests.swift` drives the check from the *types* rather
/// than from these lists — it reflects over each model's stored properties and requires its fixture
/// to differ from a default-constructed value on every one of them, then compares source and copy as
/// encoded documents with identifiers rewritten by order of first appearance. A field this file
/// forgets comes back at its default, which the fixture is guaranteed not to be using, so the
/// comparison fails and names it. Two things it still cannot do: cover `MockProject.schemaVersion`,
/// which is a `let` stamped by the initialiser and so identical in the fixture and in a
/// default-constructed project; and *insist* that the fixture varies a field belonging to a type that
/// file does not list — the encoded comparison still sees such a field, but only for as long as the
/// fixture happens to give it a value that is not the default.
extension MockProject {

    /// A copy of this project under `name`, sharing no identifier with it.
    ///
    /// Names, paths, responses and settings are preserved exactly — this is a copy, not a rename.
    /// Only identity is new, and the two references that point *into* the tree (an endpoint's active
    /// scenario, the project's active journey) are repointed at their counterparts in the copy rather
    /// than left dangling at the original's.
    ///
    /// Field list to track: of ``MockProject``'s nine stored properties, `serverConfiguration`,
    /// `endpoints`, `journeys` and `activeJourneyID` are copied and `name` is the parameter. The other
    /// four are deliberately *not* carried — `id` is new, `schemaVersion` is always the current one,
    /// and `createdAt`/`modifiedAt` take the initialiser's defaults because the copy was made now.
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
    ///
    /// Following the source's active scenario is also the semantics `mimic endpoint duplicate` gets,
    /// because a duplicate should answer the way the original does. Pointing the copy at
    /// `scenarios.first` instead means an endpoint serving "Server error" duplicates into one serving
    /// "Default" — a difference nothing on screen explains.
    ///
    /// Field list to track: of ``Endpoint``'s nine stored properties, `id` and `scenarios` are
    /// reminted and `activeScenarioID` is repointed; `name`, `method`, `path`, `delayMs`, `groupTag`
    /// and `graphqlOperation` are carried across unchanged.
    public func copyingWithFreshIdentifiers() -> Endpoint {
        let activeIndex = activeScenarioID.flatMap { active in
            scenarios.firstIndex { $0.id == active }
        }
        let copiedScenarios = scenarios.map { $0.copyingWithFreshIdentifiers() }

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

extension Scenario {

    /// This scenario with a new id, so editing the copy never rewrites the original's response.
    ///
    /// Field list to track: of ``Scenario``'s six stored properties, `id` is reminted; `name`,
    /// `statusCode`, `headers`, `body` and `bodyContentType` are carried across unchanged.
    public func copyingWithFreshIdentifiers() -> Scenario {
        Scenario(
            name: name,
            statusCode: statusCode,
            headers: headers,
            body: body,
            bodyContentType: bodyContentType
        )
    }
}

extension Journey {

    /// This journey with a new id and new step ids, in the same order.
    ///
    /// Field list to track: of ``Journey``'s eight stored properties, `id` and `steps` are reminted;
    /// `name`, `summary`, `matchMode`, `completion`, `unmatchedBehavior` and `autoAdvance` are carried
    /// across unchanged.
    public func copyingWithFreshIdentifiers() -> Journey {
        Journey(
            name: name,
            summary: summary,
            steps: steps.map { $0.copyingWithFreshIdentifiers() },
            matchMode: matchMode,
            completion: completion,
            unmatchedBehavior: unmatchedBehavior,
            autoAdvance: autoAdvance
        )
    }
}

extension JourneyStep {

    /// This step with a new id, keeping its place in the script.
    ///
    /// Field list to track: of ``JourneyStep``'s eight stored properties, `id` is reminted; `name`,
    /// `method`, `path`, `outcome`, `delayMs`, `repeatCount` and `graphqlOperation` are carried across
    /// unchanged.
    public func copyingWithFreshIdentifiers() -> JourneyStep {
        JourneyStep(
            name: name,
            method: method,
            path: path,
            outcome: outcome,
            delayMs: delayMs,
            repeatCount: repeatCount,
            graphqlOperation: graphqlOperation
        )
    }
}
