import Foundation
import Domain

/// What the endpoint editor can ask for. The editor owns no model state; every change goes through
/// one of these, so the window and the control API apply the same rules.
struct EndpointEditorActions {
    public let onRename: () -> Void
    public let onEditRequest: () -> Void
    public let onDuplicate: () -> Void
    public let onDelete: () -> Void
    public let onUpdateScenario: (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void
    public let onUpdateContentType: (Scenario.ContentType) -> Void
    public let onUpdateDelay: (Int) -> Void
    public let onUpdateGroupTag: (String?) -> Void
    public let onUpdateBackend: (UUID?) -> Void
    public let onMakeLive: (_ scenarioID: UUID) -> Void
    public let onRenameScenario: (_ scenarioID: UUID, _ name: String) -> Void
    public let onDuplicateScenario: (_ scenarioID: UUID) -> Void
    public let onDeleteScenario: (_ scenarioID: UUID) -> Void

    public init(
        onRename: @escaping () -> Void = {},
        onEditRequest: @escaping () -> Void = {},
        onDuplicate: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onUpdateScenario: @escaping (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void,
        onUpdateContentType: @escaping (Scenario.ContentType) -> Void = { _ in },
        onUpdateDelay: @escaping (Int) -> Void,
        onUpdateGroupTag: @escaping (String?) -> Void,
        onUpdateBackend: @escaping (UUID?) -> Void = { _ in },
        onMakeLive: @escaping (_ scenarioID: UUID) -> Void = { _ in },
        onRenameScenario: @escaping (_ scenarioID: UUID, _ name: String) -> Void = { _, _ in },
        onDuplicateScenario: @escaping (_ scenarioID: UUID) -> Void = { _ in },
        onDeleteScenario: @escaping (_ scenarioID: UUID) -> Void = { _ in }
    ) {
        self.onRename = onRename
        self.onEditRequest = onEditRequest
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onUpdateScenario = onUpdateScenario
        self.onUpdateContentType = onUpdateContentType
        self.onUpdateDelay = onUpdateDelay
        self.onUpdateGroupTag = onUpdateGroupTag
        self.onUpdateBackend = onUpdateBackend
        self.onMakeLive = onMakeLive
        self.onRenameScenario = onRenameScenario
        self.onDuplicateScenario = onDuplicateScenario
        self.onDeleteScenario = onDeleteScenario
    }
}
