#if DEBUG
import Domain
import Foundation
import Observation

/// A journey model with no session behind it, for previews, the gallery and tests.
///
/// Edits go through `ProjectCommandExecutor`, the same rule `AppState` applies, so a step added or
/// moved in the gallery lands where it would in the app. Nothing is saved and nothing is served; the
/// run controls change only `activeJourneyID`, and the live cursor is whatever `serverState` says.
@MainActor
@Observable
public final class JourneyPreviewModel: JourneyEditingModel {
    public var currentProject: MockProject?
    public var serverState: ServerState
    public var requestLogs: [RequestLog]
    public var selectedJourneyStepID: UUID?
    public var editingJourneyStepID: UUID?

    public var journeys: [Journey] { currentProject?.journeys ?? [] }
    public var serverConfiguration: ServerConfiguration { currentProject?.serverConfiguration ?? .default }

    public init(project: MockProject?, serverState: ServerState = .stopped, requestLogs: [RequestLog] = []) {
        currentProject = project
        self.serverState = serverState
        self.requestLogs = requestLogs
    }

    /// A project holding only these journeys.
    public convenience init(journeys: [Journey] = [], serverState: ServerState = .stopped) {
        self.init(project: MockProject(name: "Preview", journeys: journeys), serverState: serverState)
    }

    public func updateJourney(id: UUID, spec: JourneySpec) {
        run(.journeyUpdate(journey: .id(id), spec: spec))
    }

    @discardableResult
    public func addJourneyStep(journeyID: UUID, spec: JourneyStepSpec, at index: Int?) -> Journey? {
        run(.journeyStepAdd(journey: .id(journeyID), step: spec, atIndex: index))?.journey
    }

    public func updateJourneyStep(journeyID: UUID, stepID: UUID, spec: JourneyStepSpec) {
        run(.journeyStepUpdate(journey: .id(journeyID), step: .id(stepID), spec: spec))
    }

    public func removeJourneyStep(journeyID: UUID, stepID: UUID) {
        run(.journeyStepRemove(journey: .id(journeyID), step: .id(stepID)))
    }

    @discardableResult
    public func addJourneySteps(journeyID: UUID, capturing logs: [RequestLog]) -> Journey? {
        guard let steps = try? JourneyStepSpec.capturing(logs), !steps.isEmpty else { return nil }
        return run(.journeyStepsAdd(journey: .id(journeyID), steps: steps, atIndex: nil))?.journey
    }

    public func moveJourneyStep(journeyID: UUID, stepID: UUID, to index: Int) {
        run(.journeyStepMove(journey: .id(journeyID), step: .id(stepID), toIndex: index))
    }

    public func activateJourney(id: UUID?) {
        guard var project = currentProject else { return }
        if let id, !project.journeys.contains(where: { $0.id == id }) { return }
        project.activeJourneyID = id
        currentProject = project
    }

    public func restartActiveJourney() {}
    public func advanceActiveJourney() {}

    @discardableResult
    private func run(_ command: ControlCommand) -> ControlResult? {
        guard var project = currentProject,
              let outcome = try? ProjectCommandExecutor.apply(command, to: &project) else { return nil }
        if outcome.didMutate { currentProject = project }
        return outcome.result
    }
}
#endif
