import Foundation
import Domain

/// Manages a persistent list of recently opened projects backed by UserDefaults.
/// Stores up to 10 entries ordered by most-recently-opened first.
// @unchecked Sendable: the shared lock serializes complete read-modify-write operations, including
// separate store instances over the same defaults suite. UserDefaults alone protects only individual
// accesses. This is process-local synchronization, not a transaction with other processes.
public final class RecentProjectsStore: @unchecked Sendable {

    private static let lock = NSLock()
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
        Self.lock.withLock { loadEntries() }
    }

    private func loadEntries() -> [RecentProjectEntry] {
        guard let data = defaults.data(forKey: Self.key) else {
            return []
        }
        return (try? JSONDecoder().decode([RecentProjectEntry].self, from: data)) ?? []
    }

    // MARK: - Record

    /// Records or updates a project entry at the top of the list. Caps the list at 10 entries.
    ///
    /// `asLastOpened` decides whether the ID also becomes ``lastOpenedProjectID()`` — the project
    /// the app restores on next launch. The list row and the restore target used to be one
    /// unconditional write, and two callers record projects nobody has opened: a duplicate's copy
    /// and an imported document left inactive. Duplicate or import headlessly, quit without another
    /// edit, and the app came back on the copy instead of the project that was on screen. Pass
    /// `false` to add the row and leave the restore target where it is.
    public func record(id: UUID, name: String, asLastOpened: Bool = true) {
        Self.lock.withLock {
            var entries = loadEntries()
            entries.removeAll { $0.id == id }
            entries.insert(RecentProjectEntry(id: id, name: name, lastOpenedAt: Date()), at: 0)
            if entries.count > Self.maxEntries {
                entries = Array(entries.prefix(Self.maxEntries))
            }
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: Self.key)
            }
            if asLastOpened {
                defaults.set(id.uuidString, forKey: Self.lastOpenedKey)
            }
        }
    }

    // MARK: - Remove

    /// Removes the entry with the given ID. If the removed ID is the last-opened ID,
    /// the lastOpenedProjectID key is also cleared.
    public func remove(id: UUID) {
        Self.lock.withLock {
            var entries = loadEntries()
            entries.removeAll { $0.id == id }
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: Self.key)
            }
            if let lastOpened = defaults.string(forKey: Self.lastOpenedKey),
               UUID(uuidString: lastOpened) == id {
                defaults.removeObject(forKey: Self.lastOpenedKey)
            }
        }
    }

    // MARK: - Last Opened

    /// Returns the UUID of the most-recently-opened project, or nil if none is stored.
    public func lastOpenedProjectID() -> UUID? {
        Self.lock.withLock {
            guard let uuidString = defaults.string(forKey: Self.lastOpenedKey) else {
                return nil
            }
            return UUID(uuidString: uuidString)
        }
    }
}
