#if DEBUG
import AppKit
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
}
#endif
