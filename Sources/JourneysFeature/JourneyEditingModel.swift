import Domain
import Foundation
import Observation

/// What the journey screens need from the app: the open project's journeys and the live run, and
/// the edits their controls make.
///
/// `AppState` is the one production conformer. The views read and write through this protocol so the
/// module never sees the session, the store or the engine, and so the gallery and tests can draw
/// every journey screen from ``JourneyPreviewModel``. Observation still tracks each property a view
/// reads, because the conformer is an `@Observable` class whatever the static type says.
@MainActor
public protocol JourneyEditingModel: AnyObject, Observable {
    var currentProject: MockProject? { get }
    var journeys: [Journey] { get }
    var serverConfiguration: ServerConfiguration { get }
    var serverState: ServerState { get }
    var requestLogs: [RequestLog] { get }
    /// The step the step list has selected, shown in the inspector.
    var selectedJourneyStepID: UUID? { get set }
    /// The step whose sheet is open, from the list or the inspector's "Edit step…".
    var editingJourneyStepID: UUID? { get set }

    func updateJourney(id: UUID, spec: JourneySpec)
    @discardableResult
    func addJourneyStep(journeyID: UUID, spec: JourneyStepSpec, at index: Int?) -> Journey?
    func updateJourneyStep(journeyID: UUID, stepID: UUID, spec: JourneyStepSpec)
    func removeJourneyStep(journeyID: UUID, stepID: UUID)
    @discardableResult
    func addJourneySteps(journeyID: UUID, capturing logs: [RequestLog]) -> Journey?
    func moveJourneyStep(journeyID: UUID, stepID: UUID, to index: Int)
    func activateJourney(id: UUID?)
    func restartActiveJourney()
    func advanceActiveJourney()
}
