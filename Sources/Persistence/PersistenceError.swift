import Foundation

public enum PersistenceError: Error, Sendable, LocalizedError {
    case projectNotFound(UUID)
    /// A stored project written by a build that understands a later document schema than this one.
    /// Carries both numbers because "update Mimic" is only actionable when the user can see how far
    /// ahead the store is.
    case unsupportedSchemaVersion(name: String, stored: Int, supported: Int)
    /// A stored value cannot be translated without changing the project's identity or behavior.
    case corruptedRecord(table: String, id: String, field: String)

    static func requiredUUID(
        _ value: String, table: String, id: String, field: String
    ) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw Self.corruptedRecord(table: table, id: id, field: field)
        }
        return uuid
    }

    static func optionalUUID(
        _ value: String?, table: String, id: String, field: String
    ) throws -> UUID? {
        guard let value else { return nil }
        return try requiredUUID(value, table: table, id: id, field: field)
    }

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id): return "Project not found: \(id)"
        case let .unsupportedSchemaVersion(name, stored, supported):
            return """
            "\(name)" was written by a newer version of Mimic (document schema \(stored); \
            this build understands up to \(supported)). Update Mimic to open it. \
            Nothing was changed.
            """
        case let .corruptedRecord(table, id, field):
            return "Stored \(table) record \(id) has an invalid \(field). Nothing was changed."
        }
    }
}
