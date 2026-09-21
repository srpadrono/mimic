import AppKit
import Domain
import Foundation
import Observation
import Persistence

/// Drives the update flow the window shows: check, offer, download, verify, install.
///
/// One object owns the whole sequence because the states are mutually exclusive and each one decides
/// what the next may be — a design that reads as a state machine because it is one. Splitting it
/// across a checker and a downloader would put "what is happening right now" in two places, which is
/// how a progress bar ends up running under a sheet that says "up to date".
@Observable
@MainActor
final class UpdateService {

    /// Where the flow is. Exhaustive: the sheet renders from this and nothing else.
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(installed: ReleaseVersion)
        case available(UpdateRelease)
        case downloading(UpdateRelease, fraction: Double)
        case readyToInstall(UpdateRelease, installer: URL)
        case installing(UpdateRelease)
        case failed(String)

        var release: UpdateRelease? {
            switch self {
            case .idle, .checking, .upToDate, .failed: nil
            case .available(let release),
                 .downloading(let release, _),
                 .readyToInstall(let release, _), .installing(let release): release
            }
        }

        /// Whether closing the sheet now would abandon work in progress.
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: true
            case .idle, .upToDate, .available, .readyToInstall, .failed: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// Whether the update sheet is on screen.
    ///
    /// Separate from ``phase`` because they answer different questions: a background check that finds
    /// nothing runs through `.checking` and `.upToDate` without ever being shown, and the same two
    /// states are exactly what a manual check *does* show. Deriving one from the other would mean
    /// either interrupting people with "you are up to date" or never telling them.
    var isShowingSheet = false

    /// Resolved on first use, never during `init`.
    ///
    /// This is not a micro-optimisation, it is a launch bug that cost a full CI run to find. Reading
    /// it means reading `Bundle.main.infoDictionary`, and this app is sandboxed: when its bundle
    /// happens to sit under `~/Documents` — which is exactly where a build lands when `Scripts/ci.sh`
    /// uses its repo-local `.artifacts/DerivedData` — that read is a TCC-protected access to the
    /// Documents folder. Under a test runner there is nobody to answer the prompt, so the app blocks
    /// before it ever connects and the whole `MimicTests` bundle fails with "the test runner hung
    /// before establishing connection". Constructing an `AppState` must not depend on being allowed
    /// to read the folder the developer happens to have built into.
    private let resolveInstalledVersion: @Sendable () -> ReleaseVersion

    /// Memoised by hand rather than with `lazy`, because `@Observable` rewrites stored properties
    /// and cannot do that to a `lazy var`. `@ObservationIgnored` keeps both of these out of the
    /// macro's way — nothing observes the running version, which cannot change while the process is
    /// alive.
    @ObservationIgnored private var cachedInstalledVersion: ReleaseVersion?

    @ObservationIgnored private var installedVersion: ReleaseVersion {
        if let cachedInstalledVersion { return cachedInstalledVersion }
        let resolved = resolveInstalledVersion()
        cachedInstalledVersion = resolved
        return resolved
    }

    private let preferences: UpdatePreferences
    private let fetchLatestRelease: @Sendable () async throws -> UpdateRelease
    private let installer: any UpdateInstalling
    private let now: @Sendable () -> Date

    /// Takes the pre-update snapshot. Given the store's location rather than resolving it, because
    /// resolving it is main-actor work and the copy itself must not be.
    private let makeBackup: @Sendable (URL, String) -> Void
    private let flushPendingSave: @MainActor () async -> Void
    private let terminate: @MainActor () -> Void
    private var quitsAfterSheetDismissal = false

    private var work: Task<Void, Never>?

    init(
        installedVersion: @escaping @Sendable () -> ReleaseVersion,
        preferences: UpdatePreferences,
        fetchLatestRelease: @escaping @Sendable () async throws -> UpdateRelease = {
            try await UpdateFeedClient().latestRelease()
        },
        installer: any UpdateInstalling = UpdateInstaller(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeBackup: @escaping @Sendable (URL, String) -> Void = UpdateService.snapshot(of:version:),
        flushPendingSave: @escaping @MainActor () async -> Void = {
            await ControlPlaneCoordinator.shared.flushPendingSave()
        },
        terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.resolveInstalledVersion = installedVersion
        self.preferences = preferences
        self.fetchLatestRelease = fetchLatestRelease
        self.installer = installer
        self.now = now
        self.makeBackup = makeBackup
        self.flushPendingSave = flushPendingSave
        self.terminate = terminate
    }

    /// The running version, for the sheet's own prose.
    var installedVersionDescription: String { installedVersion.description }

    var checksAutomatically: Bool {
        get { preferences.checksAutomatically }
        set { preferences.checksAutomatically = newValue }
    }

    // MARK: - Checking

    /// The menu item. Always shows the sheet, including when there is nothing to report.
    ///
    /// "You are up to date" is the answer to a question somebody just asked, and swallowing it makes
    /// the menu item look broken.
    func checkForUpdates() {
        if case .installing = phase { return }
        isShowingSheet = true
        startCheck(announceWhenUpToDate: true)
    }

    /// The background check. Silent unless it finds something being offered.
    func checkAutomaticallyIfDue() {
        guard preferences.isAutomaticCheckDue(now: now()) else { return }
        startCheck(announceWhenUpToDate: false)
    }

    private func startCheck(announceWhenUpToDate: Bool) {
        guard !phase.isBusy else { return }
        work?.cancel()
        phase = .checking
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await fetchLatestRelease()
                guard !Task.isCancelled else { return }
                // Recorded on success only. A failed check must not push the next attempt a day out,
                // or one flight with no wifi would silence checks until tomorrow.
                preferences.lastCheckedAt = now()
                apply(
                    UpdateCheck.outcome(
                        installed: installedVersion,
                        latest: release,
                        skipping: preferences.skippedVersion
                    ),
                    announceWhenUpToDate: announceWhenUpToDate
                )
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                // A background failure stays out of the way; a failure somebody asked for is shown.
                if !announceWhenUpToDate { isShowingSheet = false }
            }
        }
    }

    private func apply(_ outcome: UpdateCheckOutcome, announceWhenUpToDate: Bool) {
        switch outcome {
        case .available(let release):
            phase = .available(release)
            isShowingSheet = true
        case .skipped:
            // Found, and deliberately not mentioned — unless this check was asked for by hand, which
            // is a person going looking, and the previous "skip" was about not being interrupted.
            phase = .upToDate(installed: installedVersion)
            if announceWhenUpToDate { isShowingSheet = true }
        case .upToDate:
            phase = .upToDate(installed: installedVersion)
            if !announceWhenUpToDate { isShowingSheet = false }
        }
    }

    // MARK: - Deciding

    /// Never mention this version again. A later one still will be.
    func skipCurrentVersion() {
        guard case .available = phase else { return }
        if let release = phase.release { preferences.skippedVersion = release.version }
        dismiss()
    }

    func dismiss() {
        if case .installing = phase { return }
        work?.cancel()
        work = nil
        isShowingSheet = false
        phase = .idle
    }

    /// AppKit refuses termination while this modal sheet is attached. SwiftUI's completion,
    /// not a timer or a single task yield, tells us when the sheet has really gone away.
    func sheetDidDismiss() {
        guard quitsAfterSheetDismissal else { return }
        quitsAfterSheetDismissal = false
        terminate()
    }

    // MARK: - Downloading

    func downloadAndPrepare() {
        guard case .available(let release) = phase else { return }
        phase = .downloading(release, fraction: 0)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await installer.download(release) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = phase else { return }
                        phase = .downloading(release, fraction: fraction)
                    }
                }
                guard !Task.isCancelled else { return }
                // Verification is not a step the user can skip and not one they can see fail
                // halfway: it happens before anything is offered as installable.
                try installer.verify(file, against: release)
                installer.stampQuarantine(on: file, from: release)
                guard !Task.isCancelled else { return }
                phase = .readyToInstall(release, installer: file)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Installing

    /// Drains the store, snapshots it, hands the package to macOS, and quits.
    ///
    /// The order is the point. The drain has to finish before the snapshot or the copy is of the
    /// state from before the last edit; the snapshot has to happen before the new version's
    /// migrations ever run, which is the moment this process ends; and the handoff has to complete
    /// before the app quits, because `Installer.app` reads the file out of this app's container.
    func installNow() {
        guard case .readyToInstall(let release, let file) = phase else { return }
        // Synchronous so repeated clicks cannot start overlapping installer handoffs.
        phase = .installing(release)
        let version = installedVersion.description
        work = Task { [weak self] in
            guard let self else { return }
            // Save before taking the backup. Ordinary termination also drains any work that
            // arrived during the handoff; do not bypass the app delegate's shutdown contract.
            await flushPendingSave()

            // Resolved here, on the main actor, and handed to the copy rather than looked up inside
            // it: `AppState.sessionStoreURL` is main-actor isolated, and a detached task reaching
            // for it would have to assume an isolation it does not have.
            if let storeURL = AppState.sessionStoreURL() {
                let backup = makeBackup
                await Task.detached(priority: .userInitiated) { backup(storeURL, version) }.value
            }

            do {
                try await installer.handOff(file)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            quitsAfterSheetDismissal = true
            isShowingSheet = false
        }
    }

    /// Snapshots the store. Best effort, and deliberately quiet.
    ///
    /// A snapshot is insurance, not a precondition: refusing to install because a disk was too full
    /// to copy the database would leave someone stuck on an old version *and* short of space — and
    /// the update itself cannot harm the store, since the installer writes only `/Applications` and
    /// `/usr/local/bin`. Only a migration in the *next* version could, which is what this is for.
    nonisolated static func snapshot(of storeURL: URL, version: String) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        // `_ =` because `try?` wraps the discardable result in an Optional, which is not.
        _ = try? StoreBackup.snapshot(of: storeURL, version: version)
    }
}
