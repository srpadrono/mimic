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
        let (store, _, _) = makeStore()
        #expect(store.load().isEmpty)
    }

    // MARK: - Record and load

    @Test func recordAndLoad() {
        let (store, _, _) = makeStore()
        let id = UUID()
        store.record(id: id, name: "My Project")

        let entries = store.load()
        #expect(entries.count == 1)
        #expect(entries[0].id == id)
        #expect(entries[0].name == "My Project")
    }

    // MARK: - Most recent first

    @Test func recordPrependsNewEntry() {
        let (store, _, _) = makeStore()
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
        let (store, _, _) = makeStore()
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
        let (store, _, _) = makeStore()
        for i in 0..<12 {
            store.record(id: UUID(), name: "Project \(i)")
        }
        #expect(store.load().count == 10)
    }

    // MARK: - Remove entry

    @Test func removeDeletesEntry() {
        let (store, _, _) = makeStore()
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
        let (store, _, _) = makeStore()
        let id = UUID()
        store.record(id: id, name: "Recent")
        #expect(store.lastOpenedProjectID() == id)
    }

    @Test func lastOpenedProjectIDNilWhenEmpty() {
        let (store, _, _) = makeStore()
        #expect(store.lastOpenedProjectID() == nil)
    }

    @Test func removeLastOpenedClearsKey() {
        let (store, _, _) = makeStore()
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
        let (store, _, _) = makeStore()
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
        let (store, _, _) = makeStore()
        store.record(id: UUID(), name: "Imported", asLastOpened: false)
        #expect(store.lastOpenedProjectID() == nil)
    }
}
