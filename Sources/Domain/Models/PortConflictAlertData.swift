import Foundation

/// Payload for the port conflict alert presented by UI layers.
public struct PortConflictAlertData: Identifiable, Sendable {
    public let id: UUID
    public let conflictingPort: Int
    public var suggestedPort: Int { conflictingPort + 1 }

    public init(conflictingPort: Int) {
        self.id = UUID()
        self.conflictingPort = conflictingPort
    }
}
