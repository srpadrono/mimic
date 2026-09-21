import Foundation

/// An in-process handle to a complete body. Storage belongs to the engine, not Domain.
/// Deliberately excluded from log serialization and control API responses.
public struct CapturedResponseBody: Sendable, Equatable {
    public let id: UUID
    public let byteCount: Int
    private let read: @Sendable () throws -> String

    public init(id: UUID = UUID(), byteCount: Int, read: @escaping @Sendable () throws -> String) {
        self.id = id
        self.byteCount = byteCount
        self.read = read
    }

    public func text() throws -> String { try read() }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
