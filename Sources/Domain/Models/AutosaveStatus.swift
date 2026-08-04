import Foundation

/// Autosave lifecycle state for project persistence.
public enum AutosaveStatus: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}
