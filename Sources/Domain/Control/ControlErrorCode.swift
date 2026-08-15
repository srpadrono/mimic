import Foundation

/// The dotted codes a ``ControlError`` carries, named once.
///
/// ``ControlError`` calls these "stable, greppable" strings that exist "so scripts can match on them
/// without parsing English", and `docs/CLI.md` publishes them as part of the control API. That makes
/// every one of them a contract with two ends: Domain decides which code a failure carries, and
/// `ControlServer.httpStatus` decides which HTTP status a `curl --fail` caller sees for it.
///
/// Both ends used to spell the strings out separately — the factories below `ControlError`, and a
/// `switch` over `String` in `ControlPlane` holding eight more literals — so a rename moved one end
/// only. It would look complete, too: every producer updated, every test that asserts the code
/// updated with it, and the status mapping falling silently through to `500`, which is the one answer
/// a caller cannot tell apart from Mimic having actually broken.
///
/// So the codes live here and the server switches over this type instead of over its own copies of
/// the strings. A rename is one `rawValue`, and an addition does not compile until `ControlServer`
/// says what status it answers with — that `switch` has no `default`, in the same spirit as
/// ``CommandKind/scope``.
///
/// ``ControlError/code`` stays a `String`, deliberately. A code can legitimately come from outside
/// this vocabulary — `ControlClient` reports an unexpected HTTP status as `http.502` — and a wire
/// format that refused to decode an unrecognised code would turn a surprising reply into no reply.
public enum ControlErrorCode: String, Sendable, CaseIterable {

    // MARK: Project

    case noProjectOpen = "project.noneOpen"
    case projectNotFound = "project.notFound"

    // MARK: The open document

    case endpointNotFound = "endpoint.notFound"
    case scenarioNotFound = "scenario.notFound"
    case journeyNotFound = "journey.notFound"
    case journeyStepNotFound = "journeyStep.notFound"
    case journeyTemplateNotFound = "journeyTemplate.notFound"
    case noActiveJourney = "journey.noneActive"

    // MARK: Server lifecycle

    case serverBusy = "server.busy"
    case serverPortInUse = "server.portInUse"
    case serverStartFailed = "server.startFailed"

    // MARK: The request itself

    case invalidRequest = "request.invalid"
    case undecodableRequest = "request.undecodable"
    case unauthorized = "request.unauthorized"
    case forbiddenOrigin = "request.forbiddenOrigin"

    // MARK: Mimic's own failures

    case persistenceFailure = "persistence.failure"
    case internalFailure = "internal.failure"
    /// The envelope itself would not encode, so the reply is hand-written JSON in `ControlServer`.
    /// The only code here with no `ControlError` factory, for that reason.
    case encodingFailure = "internal.encoding"
}
