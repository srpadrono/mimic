import Foundation
import Domain

/// Manages a persistent list of recently opened projects backed by UserDefaults.
/// Stores up to 10 entries ordered by most-recently-opened first.
// @unchecked Sendable: UserDefaults is thread-safe for get/set operations per Apple documentation.
// All methods on this class are stateless reads/writes to UserDefaults, so concurrent access is safe.
public final class RecentProjectsStore: @unchecked Sendable {

    private static let key = "recentProjects"
    private static let lastOpenedKey = "lastOpenedProjectID"
    private static let maxEntries = 10

    private let defaults: UserDefaults

    /// Creates a store with the given UserDefaults instance.
    /// - Parameter defaults: Defaults to `.standard`; pass a custom instance for testing.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Load

    /// Returns the current list of recent entries, ordered most-recently-opened first.
    public func load() -> [RecentProjectEntry] {
        guard let data = defaults.data(forKey: Self.key) else {
            return []
        }
        return (try? JSONDecoder().decode([RecentProjectEntry].self, from: data)) ?? []
    }

    // MARK: - Record

    /// Records or updates a project entry and makes it the most-recently-opened.
    /// Caps the list at 10 entries. Also persists the ID as lastOpenedProjectID.
    public func record(id: UUID, name: String) {
        var entries = load()
        // Remove any existing entry for this ID (avoids duplicates)
        entries.removeAll { $0.id == id }
        // Prepend the new (most recent) entry
        let newEntry = RecentProjectEntry(id: id, name: name, lastOpenedAt: Date())
        entries.insert(newEntry, at: 0)
        // Enforce max entry cap
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        // Persist
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
        defaults.set(id.uuidString, forKey: Self.lastOpenedKey)
    }

    // MARK: - Remove

    /// Removes the entry with the given ID. If the removed ID is the last-opened ID,
    /// the lastOpenedProjectID key is also cleared.
    public func remove(id: UUID) {
        var entries = load()
        entries.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
        // Clear lastOpenedProjectID if it matches the removed entry
        if let lastOpened = defaults.string(forKey: Self.lastOpenedKey),
           lastOpened == id.uuidString {
            defaults.removeObject(forKey: Self.lastOpenedKey)
        }
    }

    // MARK: - Last Opened

    /// Returns the UUID of the most-recently-opened project, or nil if none is stored.
    public func lastOpenedProjectID() -> UUID? {
        guard let uuidString = defaults.string(forKey: Self.lastOpenedKey) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }
}
