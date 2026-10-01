import Domain
import Foundation
import Observation

/// What server settings needs from the app: the running server's bound ports, and the one command
/// that applies a draft.
///
/// `AppState` is the one production conformer; the gallery and tests use ``ServerSettingsPreviewModel``.
@MainActor
public protocol ServerSettingsModel: AnyObject, Observable {
    /// The open project's name, shown under the sheet's title.
    var projectName: String? { get }
    var serverState: ServerState { get }
    /// The ports the running server actually bound, which a draft is compared with to say when a
    /// change waits on a restart.
    var boundConfiguration: ServerConfiguration? { get }
    /// Why the last command was refused, if it was.
    var lastCommandError: String? { get }
    /// Validates and applies the whole configuration as one command. `false` means it was refused.
    @discardableResult
    func applyServerConfiguration(_ configuration: ServerConfiguration) -> Bool
}

#if DEBUG
/// Server settings with no server behind it: applying validates nothing and always succeeds.
@MainActor
@Observable
public final class ServerSettingsPreviewModel: ServerSettingsModel {
    public var projectName: String?
    public var serverState: ServerState
    public var boundConfiguration: ServerConfiguration?
    public var lastCommandError: String?
    public private(set) var appliedConfiguration: ServerConfiguration?

    public init(projectName: String? = "Preview", serverState: ServerState = .stopped,
                boundConfiguration: ServerConfiguration? = nil) {
        self.projectName = projectName
        self.serverState = serverState
        self.boundConfiguration = boundConfiguration
    }

    @discardableResult
    public func applyServerConfiguration(_ configuration: ServerConfiguration) -> Bool {
        appliedConfiguration = configuration
        return true
    }
}
#endif
