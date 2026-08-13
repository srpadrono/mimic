import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
final class ProjectWorkspace {
    var currentProject: MockProject? {
        didSet {
            onCurrentProjectChanged?(currentProject)
        }
    }
    var recentProjects: [RecentProjectEntry] = []
    var autosaveStatus: AutosaveStatus = .idle
    var isRestoringProject = false
    var onCurrentProjectChanged: ((MockProject?) -> Void)?

    private let projectRepository: any ProjectRepository
    private let recentProjectsStore: RecentProjectsStore
    private var autosaveTask: Task<Void, Never>?
    private var savedStatusClearTask: Task<Void, Never>?
    /// Whether a debounced edit is still waiting to be written. Read by ``flushPendingAutosave()``,
    /// which has to know the difference between "a save is owed" and "the last one already landed".
    private var hasPendingAutosave = false
    /// Ticket for the newest ``openProject(id:)``, so a load that has been superseded cannot publish.
    private var openGeneration = 0
    /// The most recent project-lifecycle write, so the next one can wait for it.
    ///
    /// Create, duplicate and delete each answer before their write lands — the window needs the
    /// project on screen now, not a spinner — and each used to be an independent unstructured `Task`
    /// with no order between them. A script drives these back to back: `mimic project create Foo`
    /// followed immediately by `mimic project delete Foo` is two commands well inside one database
    /// round trip, and the delete could reach the store first, remove nothing, and then have the
    /// create's insert land *after* it and put the project back. `mimic project duplicate Foo` in the
    /// same position reported "not found" for a project the caller had just been told was created.
    ///
    /// A host that saves before it answers never has this problem — the price is that every caller
    /// waits out the write. Chaining the tasks gives the window the same guarantee without making it
    /// wait: the writes reach the store in the order they were asked for, whatever order the
    /// callers' replies arrive in.
    ///
    /// ``importProject(_:)`` is in the chain too, and is the only member that does *not* answer
    /// early — it awaits its own write to report whether the store took the document. Being `async`
    /// is not what puts a write in order with the others, which is the mistake it used to embody:
    /// its caller dispatches it into an untracked `Task`, so awaiting the chain without joining it
    /// ordered the import behind everything before it and nothing behind the import.
    private var storeWrites: Task<Void, Never>?

    init(
        projectRepository: any ProjectRepository,
        recentProjectsStore: RecentProjectsStore
    ) {
        self.projectRepository = projectRepository
        self.recentProjectsStore = recentProjectsStore
        // The cache synchronously, so the window has something to draw on its first frame; the store
        // a moment later, which is what actually decides the list.
        recentProjects = recentProjectsStore.load()
        refreshProjectList()
    }

    @discardableResult
    func createProject(name: String, port: Int = 8080) -> ServerConfiguration {
        // The project on screen is about to be replaced, and a debounced write may still be holding
        // the one that is leaving — see `flushPendingAutosave()`.
        flushPendingAutosave()

        let project = MockProject(
            name: name,
            serverConfiguration: ServerConfiguration(port: port, globalDelayMs: 0)
        )
        setCurrentProject(project, isRestoring: true)

        autosaveStatus = .saving
        let previousWrites = storeWrites
        storeWrites = Task { @MainActor [weak self] in
            await previousWrites?.value
            guard let self else { return }
            do {
                try await projectRepository.save(project)
                recordRecentProject(id: project.id, name: project.name)
                autosaveStatus = .saved
                scheduleSavedStatusClear()
            } catch {
                // Deliberately *not* recorded in recents. A project the store refused does not
                // exist, and the welcome window's list is reconciled against the store — by
                // `refreshProjectList`, which `recordRecentProject` kicks off itself — so the entry
                // this catch used to write vanished again almost as soon as it was made, with
                // nothing said. The failure belongs on the status the window renders, and nowhere
                // else.
                autosaveStatus = .failed(error.localizedDescription)
            }
        }

        return project.serverConfiguration
    }

    /// Opens a stored project, replacing whatever is open.
    ///
    /// Generation-guarded, because two opens in quick succession are two independent loads with no
    /// order between them: the *slower* one used to win, so clicking one project, changing your mind
    /// and clicking another could leave the window on the first. Only the load that is still the one
    /// asked for is allowed to publish.
    func openProject(id: UUID) {
        flushPendingAutosave()

        openGeneration += 1
        let generation = openGeneration
        Task { @MainActor [weak self, generation] in
            guard let self else { return }
            do {
                let project = try await projectRepository.load(id: id)
                guard generation == openGeneration else { return }
                setCurrentProject(project, isRestoring: true)
                recordRecentProject(id: project.id, name: project.name)
            } catch PersistenceError.projectNotFound {
                // Not generation-guarded: this entry names a project the store does not have, and
                // that is true whichever open won the race.
                //
                // Only this arm may strike the entry. It used to be the whole `catch`, so *every*
                // failure was treated as a missing project — see below.
                recentProjectsStore.remove(id: id)
                recentProjects = recentProjectsStore.load()
                refreshProjectList()
            } catch {
                // Everything else is a project that exists and could not be read: a locked or
                // unreadable store, or a document written by a newer build
                // (`PersistenceError.unsupportedSchemaVersion`, which `allProjects` deliberately
                // does not filter out — so the row is listed, clicked, and refused only here).
                //
                // Striking those from recents said something about the store that is not true. The
                // *list* recovers on its own — `refreshProjectList` reconciles the cache against the
                // store, so the project comes back in the tail — but its place in the order does
                // not, and `RecentProjectsStore.remove` clears `lastOpenedProjectID` along with it,
                // so the app stops reopening it on launch. Nor did anything else happen: no error
                // and no indicator, with the window still showing whatever was open before.
                //
                // The store's own description is what carries the diagnosis — for a newer document,
                // the sentence naming both schema numbers — so it goes verbatim onto
                // `autosaveStatus`, the channel `createProject`, `saveCurrentProject` and
                // `scheduleAutosave` already report a store failure on.
                //
                // What this does *not* change is the reply to `mimic project open`: that is
                // optimistic by contract — `AppControlHost` answers "Opening project." as soon as the
                // reference resolves — so a script still confirms with a follow-up `state`, where the
                // open project is simply the one it already was.
                //
                // Reported whichever open won the race, for the same reason the arm above is: a
                // load the user asked for failed, and a later one succeeding does not unfail it.
                autosaveStatus = .failed(error.localizedDescription)
            }
        }
    }

    func saveCurrentProject() {
        guard let project = currentProject else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                autosaveStatus = .saving
                try await projectRepository.save(project)
                autosaveStatus = .saved
                scheduleSavedStatusClear()
            } catch {
                autosaveStatus = .failed(error.localizedDescription)
            }
        }
    }

    func duplicateProject(id: UUID) {
        let previousWrites = storeWrites
        storeWrites = Task { @MainActor [weak self] in
            await previousWrites?.value
            guard let self else { return }
            do {
                let source = try await projectRepository.load(id: id)
                // `duplicated(name:)`, not a `MockProject` built around `source.endpoints`. Child ids
                // are primary keys across the whole database, so reusing them made every duplicate of
                // a non-empty project collide on insert and roll the write back — and this `catch`
                // is why nobody noticed. It also dropped the journeys entirely.
                let copy = source.duplicated(name: "\(source.name) (Copy)")
                try await projectRepository.save(copy)
                recordRecentProject(id: copy.id, name: copy.name)
            } catch {
                // A duplicate that fails has to say so. Swallowing it is what let a feature that
                // could not work on any project with a single endpoint in it ship silently.
                // `autosaveStatus` is the channel the window already renders for a store failure.
                autosaveStatus = .failed("Could not duplicate the project.")
            }
        }
    }

    /// Stores a document that came from outside the app, reporting whether the store took it.
    ///
    /// `AppControlHost` used to do this itself, as `Task { try? await repository.save(document) }`
    /// beside a success envelope — the same shape ``duplicateProject(id:)`` was fixed to stop using,
    /// and with the same consequence: `mimic project import` exited 0 on a save that never happened
    /// and the window said nothing. The write is still asynchronous, so the reply stays optimistic,
    /// but a failure now reaches `autosaveStatus`, which is the channel the window already renders
    /// for a store failure.
    ///
    /// It joins ``storeWrites`` the way ``createProject(name:port:)`` and ``deleteProject(id:)`` do,
    /// and answers with that write's own result.
    ///
    /// It used to only *await* the chain without joining it, on the argument that it is `async` and
    /// its caller awaits it — so anything issued afterwards was already behind it. Its caller is
    /// `AppState.importProject`, which dispatches into an untracked `Task` and returns immediately,
    /// so nothing was behind it at all: a `mimic project delete` arriving after `mimic project
    /// import` took `storeWrites` as it was *before* the import, found nothing to wait for, and was
    /// free to reach the store first — deleting nothing, and leaving the import's insert to land
    /// afterwards and put the project back. That is the inversion the chain exists to prevent, and
    /// it was open on the one command that writes a whole document.
    func importProject(_ document: MockProject) async -> Bool {
        let previousWrites = storeWrites
        let write: Task<Bool, Never> = Task { @MainActor [weak self] in
            await previousWrites?.value
            guard let self else { return false }

            autosaveStatus = .saving
            do {
                try await projectRepository.save(document)
                autosaveStatus = .saved
                scheduleSavedStatusClear()
                recordRecentProject(id: document.id, name: document.name)
                return true
            } catch {
                autosaveStatus = .failed("Could not import project \"\(document.name)\".")
                return false
            }
        }
        // The chain is a `Task<Void, Never>` because nothing awaiting it wants an answer, so what
        // goes into it is a wrapper around the write rather than the write itself. The wrapper
        // cannot finish before the write it awaits, which is the whole of what
        // `awaitPendingStoreWrites()` and the next lifecycle write need from it; the answer below
        // is the write's own.
        storeWrites = Task { @MainActor in _ = await write.value }
        return await write.value
    }

    func deleteProject(id: UUID) {
        // A debounced write for the project being removed has to go with it. It fires 500ms after the
        // last edit and re-reads `currentProject`, so a delete landing inside that window would be
        // followed by a save that puts the row straight back.
        if currentProject?.id == id { cancelPendingAutosave() }

        let previousWrites = storeWrites
        storeWrites = Task { @MainActor [weak self] in
            await previousWrites?.value
            guard let self else { return }
            do {
                try await projectRepository.delete(id: id)
            } catch {
                // `try?` here removed the recents entry and closed the project regardless, so a
                // delete the store refused looked exactly like one it accepted — and left a project
                // in the database with no row in the list to reach it by, which is the stranding
                // `refreshProjectList` exists to prevent.
                autosaveStatus = .failed("Could not delete the project.")
                return
            }
            recentProjectsStore.remove(id: id)
            recentProjects = recentProjectsStore.load()
            refreshProjectList()
            if currentProject?.id == id {
                currentProject = nil
            }
        }
    }

    func closeProject() {
        flushPendingAutosave()
        currentProject = nil
    }

    /// Waits for every project-lifecycle write already asked for.
    ///
    /// `AppControlHost` calls this before it resolves a project reference against the store, so a
    /// reference to something a previous command created resolves to the row rather than to nothing.
    /// See ``storeWrites`` for the sequence that makes this necessary.
    func awaitPendingStoreWrites() async {
        await storeWrites?.value
    }

    func scheduleAutosave() {
        guard !isRestoringProject else { return }
        guard let project = currentProject else { return }
        let projectID = project.id

        autosaveTask?.cancel()
        hasPendingAutosave = true
        autosaveTask = Task { @MainActor [weak self, projectID] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                // Claimed before the guard below: from here the write belongs to this task, and a
                // flush that ran now would only duplicate it.
                hasPendingAutosave = false
                guard let project = currentProject, project.id == projectID else { return }

                autosaveStatus = .saving
                try await projectRepository.save(project)
                autosaveStatus = .saved
                scheduleSavedStatusClear()
                recordRecentProject(id: project.id, name: project.name)
            } catch is CancellationError {
                // Superseded by a newer change.
            } catch {
                autosaveStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Writes the debounced edit now, instead of losing it.
    ///
    /// ``scheduleAutosave()`` waits 500ms and then re-reads `currentProject`, guarding that it is
    /// still the project the edit belonged to. Closing clears that property and opening another
    /// replaces it, so in both cases the pending task woke up, found the guard false and returned
    /// having saved nothing: every edit made inside the debounce window was gone, with no error and
    /// no indicator — the one failure mode this app has no way of telling you about.
    ///
    /// The project is captured *by value* here, before the property moves, so the write no longer
    /// depends on what happens to be open by the time it lands. It cannot be awaited: the callers are
    /// synchronous because a menu item and a `Button` action are.
    ///
    /// Unlike the debounced path this one does **not** touch recents. `record` makes its project the
    /// most-recently-opened one and writes `lastOpenedProjectID`, and this runs a moment before the
    /// *next* project is opened — so recording here would race the incoming open over which project
    /// the app restores on next launch. Losing the edit is the bug being fixed; the list order is not
    /// part of it, and `refreshProjectList` reads names back from the store regardless.
    private func flushPendingAutosave() {
        guard hasPendingAutosave, let project = currentProject else { return }
        cancelPendingAutosave()

        autosaveStatus = .saving
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await projectRepository.save(project)
                autosaveStatus = .saved
                scheduleSavedStatusClear()
            } catch {
                autosaveStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Forgets the debounced edit — the timer and the flag together.
    ///
    /// Called by ``flushPendingAutosave()`` once it has taken the write over, and by
    /// ``deleteProject(id:)``, which is the one case where performing the write would be wrong.
    private func cancelPendingAutosave() {
        hasPendingAutosave = false
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    @discardableResult
    func loadLastOpenedProject() -> ServerConfiguration? {
        guard let id = recentProjectsStore.lastOpenedProjectID() else { return nil }
        openProject(id: id)
        return nil
    }

    @discardableResult
    func mutateCurrentProject(_ mutation: (inout MockProject) -> Void) -> Bool {
        guard var project = currentProject else { return false }
        mutation(&project)
        currentProject = project
        return true
    }

    private func setCurrentProject(_ project: MockProject?, isRestoring: Bool) {
        if isRestoring {
            isRestoringProject = true
        }
        currentProject = project
        if isRestoring {
            isRestoringProject = false
        }
    }

    private func recordRecentProject(id: UUID, name: String) {
        recentProjectsStore.record(id: id, name: name)
        recentProjects = recentProjectsStore.load()
        refreshProjectList()
    }

    /// Reconciles the welcome window's list against the store.
    ///
    /// `RecentProjectsStore` is a `UserDefaults` cache capped at ten entries; the projects themselves
    /// live in SQLite. Listing only the cache is how the app stranded data: the welcome window is the
    /// *only* way into a project — the File menu offers New and Close and nothing else — so an
    /// eleventh project, or any project after the cache is cleared, stayed in the database with no
    /// route to it. `mimic project list` could still see it. The window could not.
    ///
    /// So the cache decides **order** and the store decides **membership**. Nothing the store holds
    /// can be unreachable, and nothing the cache remembers outlives the project it names.
    func refreshProjectList() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let stored = try? await projectRepository.allProjects() else { return }
            recentProjects = Self.reconcile(cached: recentProjectsStore.load(), stored: stored)
        }
    }

    /// Pure so the ordering is testable without a database.
    static func reconcile(
        cached: [RecentProjectEntry],
        stored: [MockProject]
    ) -> [RecentProjectEntry] {
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Cached entries keep their order, minus any the store no longer has — a project deleted by
        // the CLI, or by another window, should not sit in the list as a row that fails to open.
        // The name comes from the store, because that is what a rename updates.
        let remembered = cached.compactMap { entry -> RecentProjectEntry? in
            guard let project = byID[entry.id] else { return nil }
            return RecentProjectEntry(
                id: entry.id,
                name: project.name,
                lastOpenedAt: entry.lastOpenedAt
            )
        }

        // Then everything the cache has never heard of, most recently modified first. Without this
        // the list is a cache view; with it, it is the store.
        let remembatedIDs = Set(remembered.map(\.id))
        let forgotten = stored
            .filter { !remembatedIDs.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { RecentProjectEntry(id: $0.id, name: $0.name, lastOpenedAt: $0.modifiedAt) }

        return remembered + forgotten
    }

    private func scheduleSavedStatusClear() {
        // A single superseding task — a newer save cancels the previous timer so a stale timer can't
        // flip a freshly-`.saving` status back to `.idle`.
        savedStatusClearTask?.cancel()
        savedStatusClearTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if autosaveStatus == .saved {
                autosaveStatus = .idle
            }
        }
    }
}
