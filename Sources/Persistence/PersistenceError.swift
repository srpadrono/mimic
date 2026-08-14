import Foundation

public enum PersistenceError: Error, Sendable, LocalizedError {
    case projectNotFound(UUID)
    /// A stored project written by a build that understands a later document schema than this one.
    /// Carries both numbers because "update Mimic" is only actionable when the user can see how far
    /// ahead the store is.
    case unsupportedSchemaVersion(name: String, stored: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id): return "Project not found: \(id)"
        case let .unsupportedSchemaVersion(name, stored, supported):
            return """
            "\(name)" was written by a newer version of Mimic (document schema \(stored); \
            this build understands up to \(supported)). Update Mimic to open it. \
            Nothing was changed.
            """
        }
    }
}
