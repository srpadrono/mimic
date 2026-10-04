#if DEBUG
import AppKit
import Domain
import Foundation
import Persistence
import SwiftUI
import FeatureSupport

/// Test-only support for deterministic XCUITest launches.
///
/// Under UI testing the app must (a) start from a clean persisted state, window frame included,
/// (b) reliably bring its window to the foreground in a headless CI environment, and (c) lay its
/// window out on the same screen as CI whatever Mac it runs on. This lives behind `#if DEBUG` so none of
/// this scaffolding is compiled into Release builds — the shipping product never carries it.
///
/// Activation is gated on the `-MimicResetForTesting` launch argument or the `MIMIC_DEFAULTS_SUITE`
/// environment variable, both set only by the UI test harness.
enum UITestSupport {
    /// Only replaces external download/Installer work; the sheet and real AppKit quit still run.
    static func updateInstaller() -> (any UpdateInstalling)? {
        guard isRunningUITests,
              let outcome = ProcessInfo.processInfo.environment["MIMIC_UPDATE_INSTALL_FIXTURE"],
              ["success", "failure"].contains(outcome) else { return nil }
        return UpdateInstallerFixture(fails: outcome == "failure")
    }

    private nonisolated struct UpdateInstallerFixture: UpdateInstalling {
        let fails: Bool
        func download(_ release: UpdateRelease, onProgress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
            URL(fileURLWithPath: "/fixture/not-a-real-installer.pkg")
        }
        func verify(_ fileURL: URL, against release: UpdateRelease) throws {}
        func stampQuarantine(on fileURL: URL, from release: UpdateRelease) throws {}
        @MainActor func handOff(_ fileURL: URL) async throws {
            if fails { throw UpdateInstaller.InstallError.handoffFailed("Fixture handoff refused.") }
        }
    }

    private static let activationAttempts = 5
    private static let activationRetryDelay = Duration.milliseconds(200)
    private static var hasResetCurrentProcess = false

    /// The window sizes UI tests work at: the screen's whole visible frame, a compact width that
    /// folds the toolbar while keeping all three panels, and the two smallest the window allows,
    /// which the layout audit (`LayoutAuditUITests`) sweeps. The screen is the pinned one
    /// (``ScreenGeometry``), so each size is the same on every Mac as on CI.
    enum TestWindowSize {
        case fill
        case compact
        /// As narrow as the window's minimum size allows, at the screen's full height.
        case minimum
        /// As short as the window's minimum size allows, at the screen's full width.
        case short
    }

    /// Under 1180pt, where the toolbar folds its secondary actions, and wide enough for the
    /// navigator, the editor and the inspector together.
    static let compactTestWindowWidth: CGFloat = 900

    /// Sets the workspace window's frame directly. UI tests used to reach these sizes through
    /// Window ▸ Move & Resize or a corner drag, and both proved unreliable on CI: the menu's system
    /// items are rebuilt while it opens, and a drag stops at whatever minimum the panels allow.
    static func resizeMainWindow(to size: TestWindowSize) {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let visible = ScreenGeometry.visibleFrame(of: window.screen ?? NSScreen.main)
        else { return }
        // A resize is exactly what AppKit would record for the next launch to reopen at.
        stopFrameAutosave(window)
        var frame = visible
        switch size {
        case .fill:
            break
        case .compact:
            // Against the right edge, so menus the toolbar opens stay inside the window's screenshot.
            frame.size.width = min(compactTestWindowWidth, visible.width)
            frame.origin.x = visible.maxX - frame.width
        case .minimum:
            frame.size.width = min(minimumFrameSize(of: window).width, visible.width)
            frame.origin.x = visible.maxX - frame.width
        case .short:
            frame.size.height = min(minimumFrameSize(of: window).height, visible.height)
            frame.origin.y = visible.maxY - frame.height
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// The smallest frame the window accepts: the larger of its own `minSize` and the frame around
    /// the content minimum SwiftUI derives from the panels' floors. `setFrame` enforces neither, so
    /// asking for less would draw a window no person could make by dragging.
    private static func minimumFrameSize(of window: NSWindow) -> CGSize {
        let content = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        return CGSize(width: max(window.minSize.width, content.width, 1), height: max(window.minSize.height, content.height, 1))
    }

    // MARK: - The same screen and the same first frame as CI

    /// Set to `<width>x<height>`, in points, to pin the screen every window size is taken from.
    /// The UI test harness sets CI's visible frame, `1024x674`, on every launch (`UITestEnvironment`
    /// in `MimicUITests`, which spells this key itself because the runner links no app code).
    static let pinnedScreenEnvironmentKey = "MIMIC_UITEST_SCREEN"

    /// The size this launch pinned the screen to, or `nil`; ``ScreenGeometry`` applies it.
    static let pinnedScreenSize: CGSize? = UITestSupport.pinnedScreenSize(
        environment: ProcessInfo.processInfo.environment
    )

    /// The size `environment` pins the screen to: only on a UI test launch, and only a well-formed
    /// one. Gated like every other hook here, so a stray variable cannot shrink a developer's
    /// windows. A malformed value pins nothing, the same as no value.
    static func pinnedScreenSize(
        environment: [String: String],
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> CGSize? {
        guard isRunningUITests(environment: environment, arguments: arguments),
              let value = environment[pinnedScreenEnvironmentKey]
        else { return nil }
        let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Stops AppKit restoring this window's frame at the next launch and recording it for one.
    ///
    /// AppKit keeps where each window was left under `NSWindow Frame <autosave name>` in the app's
    /// `.standard` defaults, outside the suite a reset clears. Every UI test launch therefore
    /// reopened at the frame the previous test ended on, and `WindowRoleFrame` then recorded that
    /// frame as the workspace's. After the narrowest-window test, the next test's workspace opened
    /// 680pt wide, too narrow for the inspector, which hid itself; the test failed on CI and passed
    /// whenever it ran alone. A run also shares its bundle identifier with the developer's own
    /// Mimic, so every resize a test made became the frame their real window next opened at. An
    /// empty name records and restores nothing.
    ///
    /// Idempotent and cheap, so each view that meets the window calls it before it reads or
    /// moves the frame, whichever of them meets the window first.
    static func stopFrameAutosave(_ window: NSWindow) {
        guard isRunningUITests else { return }
        if !window.frameAutosaveName.isEmpty { _ = window.setFrameAutosaveName("") }
        if window.isRestorable { window.isRestorable = false }
    }

    /// Starts a UI test window where a clean CI runner's starts: the whole visible frame of the
    /// pinned screen, with frame autosave off.
    ///
    /// Called once per window, by `WindowRoleFrame` just before it first reads the frame, so the
    /// welcome screen centres inside the pinned frame and records it as the workspace's: the first
    /// project then opens filling the pinned screen (1024×674), as it does on CI. A relaunch that
    /// keeps the run's store, and so opens straight onto a project, starts its workspace at the
    /// same frame rather than wherever the previous process left it.
    static func prepareWindowForTesting(_ window: NSWindow) {
        guard isRunningUITests else { return }
        stopFrameAutosave(window)
        guard let visible = ScreenGeometry.visibleFrame(of: window.screen ?? NSScreen.main),
              window.frame != visible
        else { return }
        window.setFrame(visible, display: true, animate: false)
    }

    /// What AppKit names every frame it autosaves in the defaults: `NSWindow Frame <autosave name>`.
    static let autosavedWindowFramePrefix = "NSWindow Frame "

    /// What AppKit names every split view arrangement it autosaves: `NSSplitView Subview Frames
    /// <autosave name>`, each pane's frame and whether it is collapsed.
    ///
    /// SwiftUI autosaves the navigator's `NavigationSplitView` this way, under
    /// `<window autosave name>, SidebarNavigationSplitView`, in the same `.standard` domain as the
    /// window frames. So a test that hid the navigator and ended there left every later launch
    /// opening with it collapsed: on CI, `testHidingTheInspectorRemeasuresTheToolbar` hid it and
    /// `testJourneysMenuDrivesTheActiveJourney` then failed twice, retry included, looking for a
    /// Journeys tab in a navigator that was not showing (run 37190636173).
    static let autosavedSplitViewPrefix = "NSSplitView Subview Frames "

    /// Removes every window frame and split view arrangement AppKit autosaved in `defaults`, and
    /// nothing else.
    ///
    /// ``stopFrameAutosave(_:)`` keeps a run from writing new frames; this clears the ones already
    /// there, which earlier runs wrote before it existed, so the window has nothing stale to reopen
    /// at even before `WindowRoleFrame` moves it. The split views have no such switch, since SwiftUI
    /// owns the navigator's, so this is what starts each launch with the navigator open, as on a
    /// clean runner. The cost is that the developer's own Mimic, which shares the domain, next opens
    /// at its default frame and navigator width rather than where they left them.
    ///
    /// `defaults` only removes keys in its own domain, so a suite in a unit test cannot reach the
    /// app's. Called with `.standard` only from ``resetAppIfNeeded()``, never from the injectable
    /// ``resetApp(contextProvider:)`` that unit tests call: their host is the app, so its `.standard`
    /// is the developer's real one.
    static func removeAutosavedWindowFrames(from defaults: UserDefaults) {
        let prefixes = [autosavedWindowFramePrefix, autosavedSplitViewPrefix]
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }

    static var isRunningUITests: Bool {
        isRunningUITests(environment: ProcessInfo.processInfo.environment)
    }

    static func isRunningUITests(
        environment: [String: String],
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains("-MimicResetForTesting") || environment["MIMIC_DEFAULTS_SUITE"] != nil
    }

    /// Whether this process is a **unit** test bundle host rather than a running app.
    ///
    /// Distinct from ``isRunningUITests(environment:arguments:)``, which asks whether the app was
    /// *launched by* a UI test harness. This asks whether the app's code is being hosted by
    /// `xctest`, which is the case for `MimicTests` — and that process has neither the launch
    /// argument nor the defaults-suite variable, so every existing guard here waves it through.
    ///
    /// It matters because at least one unit test constructs the real composition root:
    /// `sceneInitDoesNotRebuildAppState` touches `AppSession.shared`, whose `AppState()` opens
    /// whatever store `openStore()` resolves. That has always been the developer's own
    /// `mimic.sqlite`. It went unnoticed while opening a store only *read* from it; recording which
    /// build last opened a store made it a write, and the whole point of that record is that it is
    /// trustworthy. A unit suite quietly stamping a developer's real database — the same database
    /// this repository has already lost a project from — is exactly the class of accident the rules
    /// around `databaseURL` exist to make impossible rather than unlikely.
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner for the host process, including for
    /// Swift Testing suites, which run under the same host.
    static func isRunningUnitTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    /// A throwaway store for a unit-test process that named none of its own.
    ///
    /// Beside the real one rather than in a temporary directory, so it is subject to the same
    /// sandbox container as everything else and shows up in the same place when somebody goes
    /// looking for it. `nil` outside a unit test process, so no production path can reach it.
    static func unitTestDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        guard isRunningUnitTests(environment: environment) else { return nil }
        // A run that already named a store, or that is a UI test run, is handled ahead of this.
        guard !isRunningUITests(environment: environment, arguments: arguments) else { return nil }
        guard overriddenDatabaseURL(environment: environment) == nil else { return nil }
        return try? DatabaseFactory.resolveDatabaseURL(environment: [:])
            .deletingLastPathComponent()
            .appendingPathComponent("mimic-unittests.sqlite")
    }

    /// Whether this process must not check for updates on its own.
    ///
    /// True for both kinds of test run, for two different reasons:
    ///
    /// - **A unit test run** is hosted *by the app*, so `ContentView` appears and its launch task
    ///   runs. Without this the unit suite would make a live request to GitHub on every invocation,
    ///   on every developer's machine and in CI, and would depend on the network to pass.
    /// - **A UI test run** has a bundled feed fixture, so the network is not the problem — the race
    ///   is. A background check firing three seconds after launch raises the same sheet the test is
    ///   about to open from the menu, so the assertions would sometimes be looking at a sheet the
    ///   test did not ask for. A test that drives the check explicitly is testing the thing it names.
    ///
    /// The automatic path itself is covered by `UpdateServiceTests`, which calls
    /// `checkAutomaticallyIfDue()` directly against a stub — no window, no network, no clock.
    static func suppressesAutomaticUpdateChecks(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        isRunningUnitTests(environment: environment)
            || isRunningUITests(environment: environment, arguments: arguments)
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

    /// The reset a UI test launch runs, once, before `AppState` opens the store and before any
    /// window exists: ``resetApp(contextProvider:)``, then the autosaved window frames and split
    /// view arrangements (``removeAutosavedWindowFrames(from:)``), so the first window cannot reopen
    /// at a frame, or with a navigator collapsed, as an earlier test left it.
    static func resetAppIfNeeded() {
        guard hasResetCurrentProcess == false else { return }
        hasResetCurrentProcess = true
        resetApp()
        removeAutosavedWindowFrames(from: .standard)
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
    /// - **`.standard` is not touched here at all.** It never needed to be: `AppState.resolveDefaults`
    ///   already routes a test run to the `MIMIC_DEFAULTS_SUITE` suite, so the recents list and the
    ///   panel layout a test sees are the suite's, and wiping `.standard` only ever damaged the
    ///   developer's real window arrangement. The one thing a UI test launch does remove from it is
    ///   AppKit's autosaved window frames, and that is ``resetAppIfNeeded()``'s second step rather
    ///   than this function's, so the unit tests that call this can never reach the developer's
    ///   domain. Those frames were the one piece of state a run left for the next test to inherit;
    ///   ``stopFrameAutosave(_:)`` explains how.
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

    /// The fixture the import flow should open, in place of the `NSOpenPanel` it normally runs.
    ///
    /// **A resource name inside the app's own bundle** — `mimic-uitest-review.json` and the six
    /// others in `App/Resources/UITestFixtures/`, resolved by ``importFixtureURL(for:)`` through
    /// `Bundle.main`. A value containing a `/` is still taken as a path and tilde-expanded, so
    /// pointing the hook at a file by hand keeps working; the suite does not use that form, and the
    /// history below is why.
    ///
    /// **No path is negotiated between the runner and the app any more, because two rounds of CI
    /// proved that negotiation cannot be made to work here.** The app ships with `app-sandbox` and
    /// `files.user-selected.read-write` and nothing else, so the only *absolute* paths it may read
    /// are ones a user picked in a panel — and a UI test cannot drive a panel, which is the whole
    /// reason this hook exists. `/tmp/fixture.har` is denied rather than missing.
    ///
    /// Two arrangements were tried, and both failed on the same seam:
    ///
    /// 1. **The runner wrote to a container path it spelled out, and named it here with a `~`** the
    ///    sandboxed app expanded for itself. All eight tests that need the review screen failed on a
    ///    file the app could not open; the two that need only *a* parse error passed *vacuously*,
    ///    because ``ImportWorkflow.readableParseError(_:kind:)`` appends its format guidance to any
    ///    error, a failed read included.
    /// 2. **The runner probed for the app's own Application Support** by looking for the
    ///    `mimic-uitests.sqlite` the app had just opened, so that neither side had to assert where a
    ///    container lives. **The probe found no store in either candidate directory** — not in
    ///    `~/Library/Containers/devxa.Mimic/Data/…` and not in `~/Library/Application Support/…` —
    ///    while the app itself was demonstrably running against a working store. Whatever the reason
    ///    (a container the runner is not permitted to look inside is the likeliest), the two
    ///    processes could not be made to agree on one directory, and the runner had no way to tell
    ///    "wrong path" from "denied".
    ///
    /// So the fixture moved to where the app can always read it and the runner never has to look:
    /// **inside the app bundle**. `Bundle.main` needs no entitlement, no container, and no home
    /// directory. Do not "simplify" this back to a path the runner writes — that is arrangement 1
    /// and 2 again, and it has now cost two red rounds.
    ///
    /// The cost, stated plainly rather than hidden: the fixture bytes live in
    /// `App/Resources/UITestFixtures/`, which is a `buildableFolders` entry on the `Mimic` target, so
    /// **they are copied into the Release bundle too** — about 4 KB of JSON. Only the bytes ship; all
    /// of this code is behind `#if DEBUG`. Excluding them from Release needs a configuration-scoped
    /// build phase, which is a `Project.swift` change nobody has needed badly enough yet.
    /// `SpecImportUITests` keeps every fixture's expected rows — and the literal bytes themselves —
    /// beside its assertions, and fails if the shipped resource has drifted from them.
    static let importFileEnvironmentKey = "MIMIC_IMPORT_FILE"

    /// Which importer the file is for: `har` or `openapi`, case-insensitively. Anything else — and a
    /// missing value — means no injection, because guessing from the extension would silently run
    /// the HAR parser over a spec and report its error as the spec's. Every bundled fixture is named
    /// `.json` whatever it holds, so the extension is not a hint anybody could take.
    static let importKindEnvironmentKey = "MIMIC_IMPORT_KIND"

    /// How many bytes of padding to substitute for ``importPaddingToken`` in the loaded fixture.
    ///
    /// One fixture needs a response body a byte over the importer's 1 MB limit, and a megabyte of
    /// `x` is not a thing to commit to a repository or ship in an app bundle. The bundled file
    /// carries the token instead, and the *count* comes from the test as a literal — so the fixture
    /// is still the suite's, and it does not move when `ImportCandidateBuilder.bodySizeLimit` moves.
    /// Unset, or unparseable, means the bytes are used exactly as they are on disk.
    static let importPaddingEnvironmentKey = "MIMIC_IMPORT_PADDING"

    /// The string ``importPaddingEnvironmentKey`` replaces. Spelled the same in
    /// `App/Resources/UITestFixtures/mimic-uitest-flags.json` and in `SpecImportFixtures`.
    ///
    /// `nonisolated`, like ``importFixtureData(at:paddingByteCount:)`` and for the same reason: this
    /// module compiles `MainActor`-by-default, and both are read from the detached read
    /// `ImportWorkflow.parseFile` performs. Same opt-out `SidebarQuery.anyMethodScopeID` takes.
    nonisolated static let importPaddingToken = "MIMIC_UITEST_BODY_PADDING"

    /// A fixture a UI test asked the import flow to parse, with the importer to parse it with.
    struct ImportInjection {
        let url: URL
        let kind: ImportKind
        /// Bytes of padding to substitute for ``UITestSupport/importPaddingToken``, or `nil` for
        /// none. Read by the `loadData` the caller hands to `ImportWorkflow.parseFile`.
        let paddingByteCount: Int?
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
        return ImportInjection(
            url: url,
            kind: kind,
            paddingByteCount: importPaddingByteCount(environment: environment)
        )
    }

    /// The bundled fixture `value` names — or, when it contains a `/`, the path it spells.
    ///
    /// Three lookups, and the last one is the diagnostic rather than a hope. The subdirectory form
    /// is tried first because that is where the files live in the source tree; the flat form is
    /// tried next because a buildable folder's subdirectory may be flattened into `Resources/` when
    /// the bundle is assembled, and which of the two Xcode does is not worth a test run to find out.
    /// When neither finds it, this returns the path the resource *should* have had rather than
    /// `nil`: `nil` means no injection at all, so the sheet would never open and the failure would
    /// read as "the hook did not run", while a URL that is not there fails the read with the path in
    /// the message — which is what `WorkspaceView.presentInjectedImportIfNeeded()` carries out to the
    /// runner through the sheet's error text.
    /// `nonisolated` so `UpdateFeedClient` — which is nonisolated, to keep its fetch and decode off
    /// the main actor — can resolve its feed fixtures through this same lookup instead of writing a
    /// second one. The three-step search below is the part that must not be duplicated: the built
    /// bundle **flattens** `App/Resources`, so a resolver that only looks in `UITestFixtures/` finds
    /// nothing and the run fails as a network error rather than as a missing file.
    nonisolated static func importFixtureURL(for value: String) -> URL? {
        guard !value.contains("/") else {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        if let inSubdirectory = Bundle.main.url(
            forResource: value,
            withExtension: nil,
            subdirectory: importFixtureSubdirectory
        ) {
            return inSubdirectory
        }
        if let flattened = Bundle.main.url(forResource: value, withExtension: nil) {
            return flattened
        }
        return Bundle.main.resourceURL?
            .appendingPathComponent(importFixtureSubdirectory, isDirectory: true)
            .appendingPathComponent(value)
    }

    /// The folder the fixtures sit in under `App/Resources`, and the first place they are looked for
    /// in the built bundle.
    ///
    /// `nonisolated` because `UpdateFeedClient` resolves its own feed fixtures out of the same
    /// folder, and that type is nonisolated so its fetch and decode stay off the main actor. A
    /// constant string has nothing to protect.
    nonisolated static let importFixtureSubdirectory = "UITestFixtures"

    /// The fixture's bytes, with ``importPaddingToken`` expanded when this run asked for padding.
    ///
    /// Handed to `ImportWorkflow.parseFile` as its `loadData`, so the substitution happens on the
    /// same detached read the real flow uses and every byte the parser sees still came from the
    /// file plus a count the *test* chose. A fixture with no token in it is returned unchanged: the
    /// row assertions that wanted a padded body then fail, which is the right way round — a silent
    /// pass is what a test must never be able to reach.
    ///
    /// `nonisolated` because that read happens on a detached task: this module is
    /// `MainActor`-by-default, and a `MainActor` function cannot be called from the `@Sendable`
    /// `loadData` closure `ImportWorkflow.parseFile` runs off the main actor. Everything it touches
    /// is a value type, so the opt-out costs nothing.
    nonisolated static func importFixtureData(at url: URL, paddingByteCount: Int?) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let paddingByteCount, paddingByteCount > 0,
              let text = String(data: data, encoding: .utf8),
              text.contains(importPaddingToken)
        else { return data }
        return Data(
            text.replacingOccurrences(
                of: importPaddingToken,
                with: String(repeating: "x", count: paddingByteCount)
            ).utf8
        )
    }

    static func importPaddingByteCount(environment: [String: String]) -> Int? {
        guard let value = environment[importPaddingEnvironmentKey], let count = Int(value) else {
            return nil
        }
        return count
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
/// Window sizes for UI tests, bound to shortcuts no one presses by accident. Present only in Debug
/// builds and only while the UI test harness is driving the app.
struct UITestWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            if UITestSupport.isRunningUITests {
                Button("Test: Fill Window") { UITestSupport.resizeMainWindow(to: .fill) }
                    .keyboardShortcut("f", modifiers: [.command, .option, .control])
                Button("Test: Compact Window") { UITestSupport.resizeMainWindow(to: .compact) }
                    .keyboardShortcut("c", modifiers: [.command, .option, .control])
                Button("Test: Narrowest Window") { UITestSupport.resizeMainWindow(to: .minimum) }
                    .keyboardShortcut("n", modifiers: [.command, .option, .control])
                Button("Test: Shortest Window") { UITestSupport.resizeMainWindow(to: .short) }
                    .keyboardShortcut("t", modifiers: [.command, .option, .control])
            }
        }
    }
}
#endif
