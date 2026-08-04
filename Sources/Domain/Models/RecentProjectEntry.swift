import Foundation

/// A single entry in the recent projects list.
public struct RecentProjectEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var lastOpenedAt: Date

    public init(id: UUID, name: String, lastOpenedAt: Date) {
        self.id = id
        self.name = name
        self.lastOpenedAt = lastOpenedAt
    }
}
