import Foundation

/// Closure-based actions for EndpointEditorView, injected by the composition root.
struct EndpointEditorActions {
    public let onRename: () -> Void
    public let onEditRequest: () -> Void
    public let onDuplicate: () -> Void
    public let onDelete: () -> Void
    public let onUpdateScenario: (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void
    public let onUpdateDelay: (Int) -> Void
    public let onUpdateGroupTag: (String?) -> Void
    public let onUpdateBackend: (UUID?) -> Void

    public init(
        onRename: @escaping () -> Void = {},
        onEditRequest: @escaping () -> Void = {},
        onDuplicate: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onUpdateScenario: @escaping (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void,
        onUpdateDelay: @escaping (Int) -> Void,
        onUpdateGroupTag: @escaping (String?) -> Void,
        onUpdateBackend: @escaping (UUID?) -> Void = { _ in }
    ) {
        self.onRename = onRename
        self.onEditRequest = onEditRequest
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onUpdateScenario = onUpdateScenario
        self.onUpdateDelay = onUpdateDelay
        self.onUpdateGroupTag = onUpdateGroupTag
        self.onUpdateBackend = onUpdateBackend
    }
}
