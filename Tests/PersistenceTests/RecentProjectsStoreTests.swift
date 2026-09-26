import Testing
import Foundation
import Domain
@testable import Persistence

@Suite("RecentProjectsStore")
struct RecentProjectsStoreTests {

    private func makeStore() -> (RecentProjectsStore, UserDefaults, String) {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = RecentProjectsStore(defaults: defaults)
        return (store, defaults, suiteName)
    }

    // MARK: - Load empty

    @Test func loadEmptyReturnsEmptyArray() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.load().isEmpty)
    }

    // MARK: - Record and load

    @Test func recordAndLoad() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.record(id: id, name: "My Project")

        let entries = store.load()
        #expect(entries.count == 1)
        #expect(entries[0].id == id)
        #expect(entries[0].name == "My Project")
    }

    // MARK: - Most recent first

    @Test func recordPrependsNewEntry() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let idA = UUID()
        let idB = UUID()
        store.record(id: idA, name: "Project A")
        store.record(id: idB, name: "Project B")

        let entries = store.load()
        #expect(entries.count == 2)
        #expect(entries[0].id == idB)
        #expect(entries[1].id == idA)
    }

    // MARK: - Duplicate update

    @Test func recordUpdatesExistingEntry() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.record(id: id, name: "Original Name")
        store.record(id: id, name: "Updated Name")

        let entries = store.load()
        #expect(entries.count == 1)
        #expect(entries[0].id == id)
        #expect(entries[0].name == "Updated Name")
    }

    // MARK: - Max entries cap

    @Test func maxEntriesCapped() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for i in 0..<12 {
            store.record(id: UUID(), name: "Project \(i)")
        }
        #expect(store.load().map(\.name) == [
            "Project 11", "Project 10", "Project 9", "Project 8", "Project 7",
            "Project 6", "Project 5", "Project 4", "Project 3", "Project 2",
        ])
    }

    // MARK: - Remove entry

    @Test func removeDeletesEntry() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let idA = UUID()
        let idB = UUID()
        store.record(id: idA, name: "Alpha")
        store.record(id: idB, name: "Beta")

        store.remove(id: idA)

        let entries = store.load()
        #expect(entries.count == 1)
        #expect(entries[0].id == idB)
    }

    // MARK: - lastOpenedProjectID

    @Test func lastOpenedProjectID() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.record(id: id, name: "Recent")
        #expect(store.lastOpenedProjectID() == id)
    }

    @Test func lastOpenedProjectIDNilWhenEmpty() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.lastOpenedProjectID() == nil)
    }

    @Test func removeLastOpenedClearsKey() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.record(id: id, name: "Last")
        store.remove(id: id)
        #expect(store.lastOpenedProjectID() == nil)
    }

    // MARK: - Recording without moving the restore target

    /// A duplicate's copy and an imported document earn a list row without having been opened, so
    /// recording them must not reassign the restore target: duplicate headlessly, quit without
    /// another edit, and the app has to come back on the project that was on screen — not the copy.
    @Test func recordAsNotLastOpenedKeepsTheRestoreTarget() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let onScreen = UUID()
        let copy = UUID()
        store.record(id: onScreen, name: "Checkout")
        store.record(id: copy, name: "Checkout (Copy)", asLastOpened: false)

        // The copy still takes the top row — it is the newest thing in the list — while the
        // restore target stays on the project that was actually opened.
        let entries = store.load()
        #expect(entries.count == 2)
        #expect(entries[0].id == copy)
        #expect(store.lastOpenedProjectID() == onScreen)
    }

    /// With nothing ever opened there is no restore target, and recording a never-opened project
    /// must not invent one: on next launch the app would open a project nobody had been in.
    @Test func recordAsNotLastOpenedInventsNoTarget() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(id: UUID(), name: "Imported", asLastOpened: false)
        #expect(store.lastOpenedProjectID() == nil)
    }

    @Test("Removing a project clears a lowercase persisted restore UUID")
    func removingLowercaseRestoreTarget() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try #require(UUID(uuidString: "aabbccdd-1111-2222-3333-444444444444"))
        defaults.set("aabbccdd-1111-2222-3333-444444444444", forKey: "lastOpenedProjectID")
        #expect(store.lastOpenedProjectID() == id)

        store.remove(id: id)

        #expect(store.lastOpenedProjectID() == nil)
        #expect(defaults.object(forKey: "lastOpenedProjectID") == nil)
    }

    @Test("Concurrent records across stores sharing a suite preserve every distinct project")
    func concurrentRecordsAcrossStores() throws {
        let (first, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secondDefaults = try #require(UserDefaults(suiteName: suite))
        let stores = [first, RecentProjectsStore(defaults: secondDefaults)]
        let ids = (0..<10).map { _ in UUID() }
        let ready = DispatchGroup()
        let finished = DispatchGroup()
        let start = DispatchSemaphore(value: 0)

        // Two dedicated threads are enough to contend for the shared lock. Blocking ten global
        // queue jobs until all ten start can exhaust a small CI worker pool before the test begins.
        let writers = (0..<stores.count).map { storeIndex in
            ready.enter()
            finished.enter()
            return Thread {
                ready.leave()
                start.wait()
                for index in stride(from: storeIndex, to: ids.count, by: stores.count) {
                    stores[storeIndex].record(id: ids[index], name: "Project \(index)")
                }
                finished.leave()
            }
        }
        for writer in writers { writer.start() }
        let readyResult = ready.wait(timeout: .now() + 5)
        for _ in writers { start.signal() }
        #expect(readyResult == .success, "Both writers did not become ready within five seconds")
        guard finished.wait(timeout: .now() + 5) == .success else {
            Issue.record("Concurrent preference writes did not complete within five seconds")
            return
        }

        let entries = first.load()
        #expect(entries.count == 10)
        #expect(Set(entries.map(\.id)) == Set(ids))
        #expect(first.lastOpenedProjectID() == entries.first?.id)
    }

    @Test("Unreadable preferences stay isolated and a subsequent record restores the list")
    func corruptedPreferencesRecoverInTheirOwnSuite() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (other, otherDefaults, otherSuite) = makeStore()
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        defaults.set(Data("{not a recent-project list}".utf8), forKey: "recentProjects")
        defaults.set("not-a-uuid", forKey: "lastOpenedProjectID")
        #expect(store.load().isEmpty)
        #expect(store.lastOpenedProjectID() == nil)

        let id = UUID()
        store.record(id: id, name: "Recovered")

        #expect(store.load().map(\.id) == [id])
        #expect(store.lastOpenedProjectID() == id)
        #expect(other.load().isEmpty)
        #expect(other.lastOpenedProjectID() == nil)
    }
}
