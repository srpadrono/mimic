import Foundation

/// Closure-based actions for EndpointEditorView, injected by the composition root.
struct EndpointEditorActions {
    public let onDuplicate: () -> Void
    public let onDelete: () -> Void
    public let onUpdateScenario: (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void
    public let onUpdateDelay: (Int) -> Void
    public let onUpdateGroupTag: (String?) -> Void
    /// Switch which scenario the endpoint answers with. Injected rather than reached for through
    /// `AppState`, like every other action here, so the editor stays testable as a value.
    public let onActivateScenario: (UUID) -> Void
    /// Open the new-scenario sheet. Optional: a caller that has nowhere to present it passes `nil`
    /// and the control simply omits the item.
    public let onCreateScenario: (() -> Void)?

    public init(
        onDuplicate: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onUpdateScenario: @escaping (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void,
        onUpdateDelay: @escaping (Int) -> Void,
        onUpdateGroupTag: @escaping (String?) -> Void,
        onActivateScenario: @escaping (UUID) -> Void = { _ in },
        onCreateScenario: (() -> Void)? = nil
    ) {
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onUpdateScenario = onUpdateScenario
        self.onUpdateDelay = onUpdateDelay
        self.onUpdateGroupTag = onUpdateGroupTag
        self.onActivateScenario = onActivateScenario
        self.onCreateScenario = onCreateScenario
    }
}
