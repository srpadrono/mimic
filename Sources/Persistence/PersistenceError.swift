import Foundation

public enum PersistenceError: Error, Sendable, LocalizedError {
    case projectNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id): return "Project not found: \(id)"
        }
    }
}
