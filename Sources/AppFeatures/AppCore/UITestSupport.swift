#if DEBUG
import AppKit
import Domain
import Foundation
import Persistence

/// Test-only support for deterministic XCUITest launches.
///
/// Under UI testing the app must (a) start from a clean persisted state and (b) reliably bring its
/// window to the foreground in a headless CI environment. This lives behind `#if DEBUG` so none of
/// this scaffolding is compiled into Release builds — the shipping product never carries it.
///
/// Activation is gated on the `-MimicResetForTesting` launch argument or the `MIMIC_DEFAULTS_SUITE`
/// environment variable, both set only by the UI test harness.
enum UITestSupport {
    private static let activationAttempts = 5
    private static let activationRetryDelay = Duration.milliseconds(200)
    private static var hasResetCurrentProcess = false

    static var isRunningUITests: Bool {
        isRunningUITests(environment: ProcessInfo.processInfo.environment)
    }

    static func isRunningUITests(
        environment: [String: String],
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("-MimicResetForTesting") || environment["MIMIC_DEFAULTS_SUITE"] != nil
    }

    @MainActor
    static func activateAppIfNeeded() {
        scheduleForegroundActivationIfNeeded(isRunningUITests: isRunningUITests)
    }

    @MainActor
    static func scheduleForegroundActivationIfNeeded(
        isRunningUITests: Bool,
        enqueueActivation: (@escaping @MainActor () async -> Void) -> Void = { operation in
            Task(operation: operation)
        },
        activation: @escaping @MainActor () async -> Void = performForegroundActivation
    ) {
        guard isRunningUITests else { return }
        enqueueActivation(activation)
    }

    @MainActor
    static func performForegroundActivation() async {
        for attempt in 0..<activationAttempts {
            await Task.yield()
            activateAllWindows()

            if hasPresentedWindow {
                break
            }

            guard attempt < activationAttempts - 1 else { break }
            try? await Task.sleep(for: activationRetryDelay)
        }
    }

    @MainActor
    private static func activateAllWindows() {
        NSRunningApplication.current.unhide()
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()

        for window in NSApp.windows where window.canBecomeKey {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private static var hasPresentedWindow: Bool {
        hasPresentedWindow(
            keyWindow: NSApp.keyWindow,
            mainWindow: NSApp.mainWindow,
            windows: NSApp.windows
        )
    }

    @MainActor
    static func hasPresentedWindow(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        windows: [NSWindow]
    ) -> Bool {
        keyWindow != nil
            || mainWindow != nil
            || windows.contains(where: \.isVisible)
    }

    static func resetApp(
        contextProvider: () -> (knownTestSuites: [String], databaseURL: URL?, fileManager: FileManager) = {
            defaultResetContext()
        }
    ) {
        let context = contextProvider()
        resetApp(
            knownTestSuites: context.knownTestSuites,
            databaseURL: context.databaseURL,
            fileManager: context.fileManager
        )
    }

    static func resetAppIfNeeded() {
        guard hasResetCurrentProcess == false else { return }
        hasResetCurrentProcess = true
        resetApp()
    }

    /// The store a UI test run opens, and the only one a reset may delete.
    ///
    /// `nil` outside a UI test run, which is what makes the reset inert on a developer's machine.
    /// Inside one it is either the path the harness named, or a file called `mimic-uitests.sqlite`
    /// sitting beside the real store.
    ///
    /// Beside it, rather than in `/tmp`: the app is sandboxed, so Application Support *is* its
    /// container and a path outside would need an entitlement the shipping app does not have. The
    /// name is the guard — a run can only ever open and delete a file that says what it is.
    ///
    /// `AppState` opens this, and `defaultResetContext` deletes this. One property, so the two cannot
    /// disagree about which file a test run owns.
    static func databaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard isRunningUITests(environment: environment) else { return nil }
        if let explicit = overriddenDatabaseURL(environment: environment) { return explicit }
        return try? DatabaseFactory.resolveDatabaseURL(environment: [:])
            .deletingLastPathComponent()
            .appendingPathComponent("mimic-uitests.sqlite")
    }

    /// What a reset is allowed to touch: the run's own store and the throwaway defaults suites.
    /// Never the real store.
    static func defaultResetContext(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (knownTestSuites: [String], databaseURL: URL?, fileManager: FileManager) {
        (
            knownTestSuites: ["com.devxa.Mimic.UITests"],
            databaseURL: databaseURL(environment: environment),
            fileManager: fileManager
        )
    }

    /// The store the harness told us to use, or `nil` when it did not tell us.
    ///
    /// Deliberately does *not* fall back to `DatabaseFactory.resolveDatabaseURL`, which resolves to
    /// the real Application Support path when the override is absent. Falling back is precisely the
    /// bug this guards: a reset would then delete the developer's own projects.
    static func overriddenDatabaseURL(environment: [String: String]) -> URL? {
        guard let path = environment[DatabaseFactory.databasePathEnvironmentKey], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Clears the state a UI test run is allowed to clear.
    ///
    /// This used to delete `~/Library/…/devxa.Mimic/mimic.sqlite` unconditionally — the *real*
    /// database — and to strip `recentProjects` and `lastOpenedProjectID` out of `.standard`. Running
    /// the suite on a development machine therefore destroyed whatever projects the developer had, and
    /// it did so silently, at the start of every single test. It cost this repository a project.
    ///
    /// Two changes make that impossible rather than unlikely:
    ///
    /// - **The only files this can delete are the one ``databaseURL(environment:)`` names and
    ///   SQLite's sidecars beside it, and that name is `nil` outside a UI test run.** The sidecars
    ///   are ``sidecarURLs(for:)``, derived from the same name rather than searched for. The gate is
    ///   ``isRunningUITests(environment:arguments:)`` —
    ///   `-MimicResetForTesting`, or `MIMIC_DEFAULTS_SUITE` — and nothing else. Inside a run the file
    ///   is the path the harness put in `MIMIC_DATABASE_PATH`, or, when it set none,
    ///   `mimic-uitests.sqlite` computed beside the real store. `AppState.openStore` opens that same
    ///   property, so the file a run writes and the file a run removes cannot drift apart.
    ///
    ///   This bullet used to read "the database is only ever deleted when `MIMIC_DATABASE_PATH` names
    ///   it. No override, no deletion." That is false, and was false when it was written:
    ///   ``databaseURL(environment:)`` falls back to `mimic-uitests.sqlite` for *any* UI test run, and
    ///   `uiTestResetContextIsInertOutsideAUITestRun` in `MimicTests` asserts exactly that fallback —
    ///   in the same test, and a few lines after, the assertion that `MIMIC_DATABASE_PATH` on its own
    ///   does **not** arm the reset. So the override is neither necessary nor sufficient: it is the
    ///   UI-test gate that keeps a developer's machine safe, and believing otherwise is how somebody
    ///   would come to "simplify" that gate away.
    /// - **`.standard` is not touched at all.** It never needed to be: `AppState.resolveDefaults`
    ///   already routes a test run to the `MIMIC_DEFAULTS_SUITE` suite, so the recents list and the
    ///   panel layout a test sees are the suite's, and wiping `.standard` only ever damaged the
    ///   developer's real window arrangement.
    static func resetApp(
        knownTestSuites: [String],
        databaseURL: URL?,
        fileManager: FileManager
    ) {
        for suite in knownTestSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        guard let databaseURL else { return }
        try? fileManager.removeItem(at: databaseURL)
        for sidecar in sidecarURLs(for: databaseURL) {
            try? fileManager.removeItem(at: sidecar)
        }
    }

    /// The files SQLite keeps beside a store: `<name>-wal`, `<name>-shm`, `<name>-journal`.
    ///
    /// The suffix goes on the *file name*; it is not a path extension. This was
    /// `databaseURL.appendingPathExtension("wal")`, which names `mimic-uitests.sqlite.wal` — a file
    /// SQLite has never written — so the reset removed the store and left every sidecar it was
    /// written to remove sitting next to it. That is not inert: a journal or a write-ahead log
    /// outliving its database is recovered from at the next open, so pages the previous run committed
    /// can reappear in a store the run asked to be empty, and the failure looks like a test asserting
    /// against another test's fixtures.
    ///
    /// All three names, rather than the one the current configuration produces: `DatabaseFactory`
    /// sets no `journalMode`, so a `DatabaseQueue` writes `-journal`, and a configuration that later
    /// asks for WAL writes `-wal` and `-shm` instead. A reset that has to be revisited when a
    /// persistence setting changes is a reset that will not be.
    ///
    /// Derived from `databaseURL` alone, which is `nil` outside a UI test run — this never computes a
    /// path of its own, for the reason ``resetApp(knownTestSuites:databaseURL:fileManager:)`` gives.
    static func sidecarURLs(for databaseURL: URL) -> [URL] {
        let directory = databaseURL.deletingLastPathComponent()
        return ["-wal", "-shm", "-journal"].map {
            directory.appendingPathComponent(databaseURL.lastPathComponent + $0)
        }
    }

    // MARK: - Forcing an autosave failure

    /// Set to `1` to make every project write fail for the run.
    ///
    /// This exists because `AutosaveStatusIndicator`'s `.failed` arm was unreachable. It is set from
    /// a thrown repository error and nothing else, and every store the app can open is a GRDB queue
    /// that succeeds — the on-disk one and the in-memory fallback both — so the one arm that tells a
    /// user their work is *not* being saved could not be produced by any sequence of clicks, and the
    /// suite could not assert on it.
    static let failProjectWritesEnvironmentKey = "MIMIC_FAIL_PROJECT_WRITES"

    /// Wraps `repository` in ``WriteFailingProjectRepository`` when this run asked for it, and hands
    /// back the real store otherwise.
    ///
    /// Two gates, both required, and neither is padding. ``isRunningUITests(environment:arguments:)``
    /// is the same gate the store isolation stands on: a plain environment variable must not be able
    /// to turn a developer's session into one that silently discards every save, which is the
    /// `mimic.sqlite` failure class wearing a different hat — the damage would look exactly like
    /// "my edits keep disappearing". The value must be the literal `1`, not merely present, so that
    /// exporting the key empty to turn the hook *off* does what it reads like.
    ///
    /// Do not widen either gate, and do not let this decide for itself which store to decorate: it
    /// takes the repository it is given.
    static func projectRepositoryFailingWritesIfRequested(
        _ repository: any ProjectRepository,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any ProjectRepository {
        guard isRunningUITests(environment: environment),
              environment[failProjectWritesEnvironmentKey] == "1"
        else { return repository }
        return WriteFailingProjectRepository(base: repository)
    }

    // MARK: - Injecting a spec import

    /// The file the import flow should open, in place of the `NSOpenPanel` it normally runs.
    ///
    /// **A bare file name.** It is resolved inside ``importFixtureDirectory()`` — the app's own
    /// `Application Support/devxa.Mimic`, the directory `mimic-uitests.sqlite` sits in. A value with
    /// a `/` in it is still taken as a path and tilde-expanded, so an absolute path keeps working;
    /// the suite does not use that form, and the paragraph below is why.
    ///
    /// The app ships with `app-sandbox` and `files.user-selected.read-write` and nothing else, so
    /// the only *absolute* paths it may read are ones a user picked in a panel — and a UI test
    /// cannot drive a panel, which is the whole reason this hook exists. `/tmp/fixture.har` is
    /// therefore denied rather than missing. This key used to close that gap with a tilde: the
    /// sandboxed app expands `~` into its container, where it reads without an entitlement, so the
    /// unsandboxed runner wrote to
    /// `~/Library/Containers/devxa.Mimic/Data/Library/Application Support/devxa.Mimic/…` and named
    /// it `~/Library/Application Support/devxa.Mimic/…` here.
    ///
    /// **On its first CI run every one of the eight tests that needed the review screen failed on
    /// that arrangement, and the two that needed only *a* parse error passed.** Those two passed
    /// *vacuously*: ``ImportWorkflow.readableParseError(_:kind:)`` appends its format guidance to
    /// any error, a file the app could not open included, so "Parse error" plus "Mimic reads
    /// HAR 1.2" is exactly what a missing file produces too. What their passing does prove is that
    /// everything except the read works — the `.task` runs, this key is read, the sheet presents,
    /// the error arm renders. The read was failing because the two halves were naming different
    /// files: one side computes a path from `homeDirectoryForCurrentUser` and spells a container
    /// out, the other asks `expandingTildeInPath`, and those are two answers to "where is home"
    /// that the sandbox is free to disagree about — with no way to tell from the outside which of
    /// them was wrong.
    ///
    /// The name form does not re-decide that question, it removes it. The app resolves the fixture
    /// into a directory it already demonstrably reads and writes, because its store is in there;
    /// the runner finds that same directory by looking for the store the app just wrote, rather
    /// than asserting where a container has to be. Neither side expands a tilde. Do not "simplify"
    /// this back into a path — and do not point it at a temporary directory, because that
    /// simplification is the one the sandbox actually refuses.
    static let importFileEnvironmentKey = "MIMIC_IMPORT_FILE"

    /// Which importer the file is for: `har` or `openapi`, case-insensitively. Anything else — and a
    /// missing value — means no injection, because guessing from the extension would silently run
    /// the HAR parser over a spec and report its error as the spec's.
    static let importKindEnvironmentKey = "MIMIC_IMPORT_KIND"

    /// A file a UI test asked the import flow to parse, with the importer to parse it with.
    struct ImportInjection {
        let url: URL
        let kind: ImportKind
    }

    /// What this run wants imported, or `nil` when it wants nothing — which is every run that is not
    /// a UI test, because the gate is ``isRunningUITests(environment:arguments:)`` before it is
    /// anything else.
    ///
    /// Only the *panel* is bypassed. The caller hands the URL to
    /// `ImportWorkflow.parseFile(at:existingEndpoints:loadData:parse:)`, so the real parser runs over
    /// the real bytes, the review sheet lists the real candidates, and the commit is
    /// `AppState.commitImportedCandidates` as it always was. Injecting candidates instead of a file
    /// would be a test that builds its fixture with the mechanism under test, and it would go green
    /// over a parser that had stopped working.
    static func importInjection(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ImportInjection? {
        guard isRunningUITests(environment: environment),
              let value = environment[importFileEnvironmentKey], !value.isEmpty,
              let kind = importKind(named: environment[importKindEnvironmentKey]),
              let url = importFixtureURL(for: value)
        else { return nil }
        return ImportInjection(url: url, kind: kind)
    }

    /// Where a bare ``importFileEnvironmentKey`` name is looked for: the app's own
    /// `Application Support/devxa.Mimic`, computed exactly as ``databaseURL(environment:)`` computes
    /// the run's store when the harness names none.
    ///
    /// That shared derivation is the point. Whatever this expression resolves to — a container under
    /// the sandbox, a real home without one — is the directory the app opens
    /// `mimic-uitests.sqlite` in, so a test outside the sandbox can *find* it by looking for that
    /// file rather than reconstructing it from a rule about where containers live. The two halves
    /// then cannot name different directories, which is the failure recorded on
    /// ``importFileEnvironmentKey``.
    ///
    /// `environment: [:]`, so this is the directory the store *falls back* to and not wherever
    /// `MIMIC_DATABASE_PATH` may point instead. A run that overrides its store path still keeps its
    /// fixtures here — and a suite that overrides it can no longer find this directory by the store,
    /// which is worth knowing before adding one to the import suite.
    static func importFixtureDirectory() -> URL? {
        try? DatabaseFactory.resolveDatabaseURL(environment: [:]).deletingLastPathComponent()
    }

    /// The file `value` names: a path when it contains a `/`, otherwise a name inside
    /// ``importFixtureDirectory()``.
    ///
    /// The path arm is kept so an absolute or tilde-relative value behaves as it always did — it is
    /// how somebody would point the hook at a file by hand — and it is deliberately *not* what the
    /// suite uses.
    static func importFixtureURL(for value: String) -> URL? {
        guard !value.contains("/") else {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return importFixtureDirectory()?.appendingPathComponent(value)
    }

    static func importKind(named name: String?) -> ImportKind? {
        guard let name = name?.lowercased() else { return nil }
        switch name {
        case "har": return .har
        case "openapi": return .openAPI
        default: return nil
        }
    }
}
#endif
