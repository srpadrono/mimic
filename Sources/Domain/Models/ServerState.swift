import Foundation

public enum ServerState: Sendable, Equatable {
    case stopped
    case starting
    case running(port: Int)
    case stopping
    case error(String)

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// The port being served, or `nil` when nothing is listening.
    ///
    /// Anything that builds a URL for the user — the status bar, the `curl` command in the request
    /// inspector — needs this, and each of them reaching into the enum meant each of them deciding
    /// separately what a stopped server's URL should say.
    public var runningPort: Int? {
        if case let .running(port) = self { return port }
        return nil
    }
}
