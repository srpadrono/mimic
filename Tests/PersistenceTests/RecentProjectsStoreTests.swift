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
}
