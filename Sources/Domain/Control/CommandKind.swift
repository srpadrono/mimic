import Foundation

/// The name of a command, with the payload stripped off.
///
/// `ControlCommand` carries associated values, so it can never be `CaseIterable` — and without a way
/// to enumerate the surface, every list that claims to mirror it is a copy maintained by hand. There
/// were three: the enum itself, ``CommandCatalog``, and a set of string literals in `DomainTests`
/// that existed to prove the first two agreed. The proof did not hold. Adding a case to
/// `ControlCommand` and forgetting the catalog left all three files compiling and that test passing,
/// because the literals it compared the catalog against were themselves the thing that had not been
/// updated — it only ever checked the catalog against a copy of itself.
///
/// This enum is the join. It has no payloads, so it *is* `CaseIterable`; ``ControlCommand/kind``
/// maps onto it through a switch with no `default`, so adding a command stops the build until it is
/// named here; and the catalog can then be checked against `allCases` — a list nobody writes twice.
public enum CommandKind: String, CaseIterable, Sendable, Codable {

    // Discovery
    case ping
    case describeCommands

    // State
    case state
    case reset

    // Projects
    case projectList
    case projectCreate
    case projectOpen
    case projectClose
    case projectDelete
    case projectRename
    case projectDuplicate
    case projectExport
    case projectImport

    // Server
    case serverStart
    case serverStop
    case serverStatus
    case serverConfigure

    // Endpoints
    case endpointList
    case endpointGet
    case endpointCreate
    case endpointUpdate
    case endpointDelete
    case endpointDuplicate

    // Scenarios
    case scenarioList
    case scenarioCreate
    case scenarioUpdate
    case scenarioDelete
    case scenarioActivate

    // Journeys
    case journeyList
    case journeyGet
    case journeyCreate
    case journeyTemplateList
    case journeyAddTemplate
    case journeyUpdate
    case journeyDelete
    case journeyDuplicate
    case journeyStepAdd
    case journeyStepsAdd
    case journeyStepUpdate
    case journeyStepRemove
    case journeyStepMove
    case journeyActivate
    case journeyRestart
    case journeyAdvance
    case journeyStatus

    // Logs
    case logList
    case logClear
}

extension ControlCommand {

    /// Which command this is, ignoring what it was called with.
    ///
    /// The switch is exhaustive on purpose: it is the compiler check that keeps ``CommandKind`` — and
    /// through it the catalog, and through the catalog every agent that discovers Mimic at runtime —
    /// from falling behind the enum.
    public var kind: CommandKind {
        switch self {
        case .ping: .ping
        case .describeCommands: .describeCommands
        case .state: .state
        case .reset: .reset
        case .projectList: .projectList
        case .projectCreate: .projectCreate
        case .projectOpen: .projectOpen
        case .projectClose: .projectClose
        case .projectDelete: .projectDelete
        case .projectRename: .projectRename
        case .projectDuplicate: .projectDuplicate
        case .projectExport: .projectExport
        case .projectImport: .projectImport
        case .serverStart: .serverStart
        case .serverStop: .serverStop
        case .serverStatus: .serverStatus
        case .serverConfigure: .serverConfigure
        case .endpointList: .endpointList
        case .endpointGet: .endpointGet
        case .endpointCreate: .endpointCreate
        case .endpointUpdate: .endpointUpdate
        case .endpointDelete: .endpointDelete
        case .endpointDuplicate: .endpointDuplicate
        case .scenarioList: .scenarioList
        case .scenarioCreate: .scenarioCreate
        case .scenarioUpdate: .scenarioUpdate
        case .scenarioDelete: .scenarioDelete
        case .scenarioActivate: .scenarioActivate
        case .journeyList: .journeyList
        case .journeyGet: .journeyGet
        case .journeyCreate: .journeyCreate
        case .journeyTemplateList: .journeyTemplateList
        case .journeyAddTemplate: .journeyAddTemplate
        case .journeyUpdate: .journeyUpdate
        case .journeyDelete: .journeyDelete
        case .journeyDuplicate: .journeyDuplicate
        case .journeyStepAdd: .journeyStepAdd
        case .journeyStepsAdd: .journeyStepsAdd
        case .journeyStepUpdate: .journeyStepUpdate
        case .journeyStepRemove: .journeyStepRemove
        case .journeyStepMove: .journeyStepMove
        case .journeyActivate: .journeyActivate
        case .journeyRestart: .journeyRestart
        case .journeyAdvance: .journeyAdvance
        case .journeyStatus: .journeyStatus
        case .logList: .logList
        case .logClear: .logClear
        }
    }
}

extension CommandCatalog {

    /// The kinds the catalog actually describes.
    ///
    /// `compactMap` rather than a force-unwrap because a descriptor whose name is not a real command
    /// should be *reported* by the test that calls this, not crash it — and dropping it here is what
    /// makes the count comparison catch it.
    public static var describedKinds: Set<CommandKind> {
        Set(descriptors.compactMap { CommandKind(rawValue: $0.name) })
    }
}
