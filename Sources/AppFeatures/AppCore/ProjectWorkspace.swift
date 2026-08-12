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
        let project = MockProject(
            name: name,
            serverConfiguration: ServerConfiguration(port: port, globalDelayMs: 0)
        )
        setCurrentProject(project, isRestoring: true)

        autosaveStatus = .saving
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await projectRepository.save(project)
                recordRecentProject(id: project.id, name: project.name)
                autosaveStatus = .saved
                scheduleSavedStatusClear()
            } catch {
                recordRecentProject(id: project.id, name: project.name)
                autosaveStatus = .failed(error.localizedDescription)
            }
        }

        return project.serverConfiguration
    }

    @discardableResult
    func openProject(id: UUID) -> ServerConfiguration? {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let project = try await projectRepository.load(id: id)
                setCurrentProject(project, isRestoring: true)
                recordRecentProject(id: project.id, name: project.name)
            } catch {
                recentProjectsStore.remove(id: id)
                recentProjects = recentProjectsStore.load()
                refreshProjectList()
            }
        }

        return nil
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
        Task { @MainActor [weak self] in
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

    func deleteProject(id: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await projectRepository.delete(id: id)
            recentProjectsStore.remove(id: id)
            recentProjects = recentProjectsStore.load()
            refreshProjectList()
            if currentProject?.id == id {
                currentProject = nil
            }
        }
    }

    func closeProject() {
        currentProject = nil
    }

    func scheduleAutosave() {
        guard !isRestoringProject else { return }
        guard let project = currentProject else { return }
        let projectID = project.id

        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self, projectID] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
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

    @discardableResult
    func loadLastOpenedProject() -> ServerConfiguration? {
        guard let id = recentProjectsStore.lastOpenedProjectID() else { return nil }
        _ = openProject(id: id)
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
