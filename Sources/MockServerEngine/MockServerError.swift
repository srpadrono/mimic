import Foundation
import Domain

public enum MockServerError: Error, Sendable, LocalizedError {
    case portInUse(port: Int)
    case alreadyRunning
    case notRunning
    case invalidState(ServerState)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port):
            return "Port \(port) is already in use."
        case .alreadyRunning:
            return "Server is already running."
        case .notRunning:
            return "Server is not running."
        case .invalidState(let state):
            return "Cannot perform operation in state: \(state)."
        }
    }
}
