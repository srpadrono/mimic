import Foundation

/// Payload for the port conflict alert presented by UI layers.
public struct PortConflictAlertData: Identifiable, Sendable {
    public let id: UUID
    public let conflictingPort: Int
    /// A valid candidate not already assigned to another configured backend. Another process may
    /// still own that port; the server confirms availability when the user retries the bind.
    public let suggestedPort: Int?

    public init(conflictingPort: Int, avoiding usedPorts: Set<Int> = []) {
        self.id = UUID()
        self.conflictingPort = conflictingPort
        self.suggestedPort = Self.nextAvailablePort(after: conflictingPort, avoiding: usedPorts)
    }

    public static func nextAvailablePort(after conflictingPort: Int, avoiding usedPorts: Set<Int>) -> Int? {
        guard (1..<65535).contains(conflictingPort) else { return nil }
        return ((conflictingPort + 1)...65535).first { !usedPorts.contains($0) }
    }
}
