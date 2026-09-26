import Domain
import Foundation
import Persistence
import Testing
@testable import AppFeatures

// MARK: - Preferences

@Suite("Update preferences")
struct UpdatePreferencesTests {

    private func makePreferences() throws -> UpdatePreferences {
        let suite = try #require(UserDefaults(suiteName: "UpdatePreferencesTests.\(UUID().uuidString)"))
        return UpdatePreferences(defaults: suite)
    }

    /// `bool(forKey:)` answers `false` for a key nobody wrote, which is indistinguishable from
    /// somebody having turned checks off — and would make the shipped default the opposite of the
    /// one intended, silently, for every new install.
    @Test("Checking automatically is on before anyone has said anything")
    func automaticChecksDefaultToOn() throws {
        let preferences = try makePreferences()

        #expect(preferences.checksAutomatically)

        preferences.checksAutomatically = false
        #expect(!preferences.checksAutomatically)
        preferences.checksAutomatically = true
        #expect(preferences.checksAutomatically)
    }

    @Test("A check is due when none has ever been made")
    func firstCheckIsDue() throws {
        let preferences = try makePreferences()
        #expect(preferences.isAutomaticCheckDue(now: Date(timeIntervalSince1970: 1_787_493_751)))
    }

    @Test("A check is due a day after the last one, and not before")
    func checkIsDueOnceADay() throws {
        let preferences = try makePreferences()
        let checkedAt = Date(timeIntervalSince1970: 1_787_493_751)
        preferences.lastCheckedAt = checkedAt

        #expect(!preferences.isAutomaticCheckDue(now: checkedAt))
        #expect(!preferences.isAutomaticCheckDue(now: checkedAt.addingTimeInterval(60 * 60 * 23)))
        #expect(preferences.isAutomaticCheckDue(now: checkedAt.addingTimeInterval(60 * 60 * 24)))
        #expect(preferences.isAutomaticCheckDue(now: checkedAt.addingTimeInterval(60 * 60 * 48)))
    }

    /// A clock that moved backwards — a restored backup, a corrected system time — would otherwise
    /// leave `now - lastCheckedAt` negative, which reads as "not due yet" for as long as it takes
    /// real time to catch up. That can be months.
    @Test("A last-checked time in the future does not disable checking")
    func clockMovingBackwardsDoesNotStallChecks() throws {
        let preferences = try makePreferences()
        let now = Date(timeIntervalSince1970: 1_787_493_751)
        preferences.lastCheckedAt = now.addingTimeInterval(60 * 60 * 24 * 365)

        #expect(preferences.isAutomaticCheckDue(now: now))
    }

    @Test("Turning checks off stops them being due")
    func disabledMeansNeverDue() throws {
        let preferences = try makePreferences()
        preferences.checksAutomatically = false

        #expect(!preferences.isAutomaticCheckDue(now: Date(timeIntervalSince1970: 1_787_493_751)))
    }

    @Test("A skipped version round-trips, and can be cleared")
    func skippedVersionPersists() throws {
        let preferences = try makePreferences()
        #expect(preferences.skippedVersion == nil)

        preferences.skippedVersion = ReleaseVersion("0.11.0")
        #expect(preferences.skippedVersion == ReleaseVersion(major: 0, minor: 11, patch: 0))

        preferences.skippedVersion = nil
        #expect(preferences.skippedVersion == nil)
    }
}

// MARK: - The service

@MainActor
@Suite("Update service")
struct UpdateServiceTests {

    private actor HeldFeed {
        private var fetchContinuation: CheckedContinuation<UpdateRelease, any Error>?
        private var arrivalContinuation: CheckedContinuation<Void, Never>?
        private(set) var fetchCount = 0

        func fetch() async throws -> UpdateRelease {
            fetchCount += 1
            arrivalContinuation?.resume()
            arrivalContinuation = nil
            return try await withCheckedThrowingContinuation { fetchContinuation = $0 }
        }

        func waitForFetch() async {
            guard fetchCount == 0 else { return }
            await withCheckedContinuation { arrivalContinuation = $0 }
        }

        func complete(with release: UpdateRelease) {
            fetchContinuation?.resume(returning: release)
            fetchContinuation = nil
        }
    }

    /// `nonisolated` because the stub fetch below is a `@Sendable` closure evaluated outside the
    /// main actor, and this suite is `@MainActor`. `UpdateRelease` is a `Sendable` value.
    nonisolated static func release(_ version: String) -> UpdateRelease {
        UpdateRelease(
            version: ReleaseVersion(version)!,
            tag: "v\(version)",
            title: "Mimic v\(version)",
            notes: "Notes.",
            pageURL: URL(string: "https://example.invalid/tag/v\(version)")!,
            publishedAt: Date(timeIntervalSince1970: 1_787_420_565),
            asset: UpdateRelease.Asset(
                name: "Mimic-\(version).pkg",
                downloadURL: URL(string: "https://example.invalid/Mimic-\(version).pkg")!,
                sizeInBytes: 54_618_197,
                sha256: String(repeating: "a", count: 64)
            )
        )
    }

    private struct FeedUnreachable: Error, LocalizedError {
        var errorDescription: String? { "The network is not available." }
    }

    private func makeService(
        installed: String = "0.10.0",
        latest: @escaping @Sendable () async throws -> UpdateRelease = { UpdateServiceTests.release("0.11.0") }
    ) throws -> (service: UpdateService, preferences: UpdatePreferences) {
        let suite = try #require(UserDefaults(suiteName: "UpdateServiceTests.\(UUID().uuidString)"))
        let preferences = UpdatePreferences(defaults: suite)
        let service = UpdateService(
            installedVersion: { ReleaseVersion(installed)! },
            preferences: preferences,
            fetchLatestRelease: latest,
            now: { Date(timeIntervalSince1970: 1_787_493_751) },
            // Never touches a disk in a test. The real one is exercised by `StoreBackupTests`.
            makeBackup: { _, _ in }
        )
        return (service, preferences)
    }

    /// Waits for the service's in-flight work to settle.
    ///
    /// The service owns its `Task` privately — deliberately, since nothing outside it should be able
    /// to interleave with a check — so a test polls the published phase rather than awaiting a
    /// handle. Bounded, so a hang fails the test instead of hanging the suite.
    private func settle(_ service: UpdateService, until predicate: (UpdateService.Phase) -> Bool) async {
        for _ in 0..<200 where !predicate(service.phase) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A newer release is offered, and raises the sheet")
    func availableReleaseIsOffered() async throws {
        let (service, _) = try makeService()

        service.checkForUpdates()
        await settle(service) { if case .available = $0 { true } else { false } }

        #expect(service.phase == .available(Self.release("0.11.0")))
        #expect(service.isShowingSheet)
    }

    /// A manual check that finds nothing still has to say so — swallowing the answer makes the menu
    /// item look broken.
    @Test("A manual check reports being up to date")
    func manualCheckAnnouncesUpToDate() async throws {
        let (service, _) = try makeService(latest: { UpdateServiceTests.release("0.10.0") })

        service.checkForUpdates()
        await settle(service) { if case .upToDate = $0 { true } else { false } }

        #expect(service.phase == .upToDate(installed: ReleaseVersion("0.10.0")!))
        #expect(service.isShowingSheet)
    }

    @Test("A background check that finds nothing stays silent")
    func automaticCheckIsSilentWhenUpToDate() async throws {
        let (service, _) = try makeService(latest: { UpdateServiceTests.release("0.10.0") })

        service.checkAutomaticallyIfDue()
        await settle(service) { if case .upToDate = $0 { true } else { false } }

        #expect(!service.isShowingSheet)
    }

    @Test("A manual check during an automatic check receives the result already in flight")
    func manualCheckPromotesAutomaticCheck() async throws {
        let feed = HeldFeed()
        let (service, _) = try makeService(
            latest: { try await feed.fetch() }
        )

        service.checkAutomaticallyIfDue()
        await feed.waitForFetch()
        service.checkForUpdates()
        await feed.complete(with: Self.release("0.10.0"))
        await settle(service) { if case .upToDate = $0 { true } else { false } }

        #expect(service.phase == .upToDate(installed: ReleaseVersion("0.10.0")!))
        #expect(service.isShowingSheet)
        #expect(await feed.fetchCount == 1)
    }

    @Test("A background check that finds something raises the sheet")
    func automaticCheckAnnouncesAnUpdate() async throws {
        let (service, _) = try makeService()

        service.checkAutomaticallyIfDue()
        await settle(service) { if case .available = $0 { true } else { false } }

        #expect(service.isShowingSheet)
    }

    @Test("A background check does not run when one has already run today")
    func automaticCheckRespectsTheInterval() async throws {
        let (service, preferences) = try makeService()
        preferences.lastCheckedAt = Date(timeIntervalSince1970: 1_787_493_751)

        service.checkAutomaticallyIfDue()

        #expect(service.phase == .idle)
        #expect(!service.isShowingSheet)
    }

    // MARK: Failure

    /// A failed check must not push the next attempt a day out, or one flight with no wifi silences
    /// checking until tomorrow.
    @Test("A failed check does not count as a check")
    func failureDoesNotRecordACheckTime() async throws {
        let (service, preferences) = try makeService(latest: { throw FeedUnreachable() })

        service.checkForUpdates()
        await settle(service) { if case .failed = $0 { true } else { false } }

        #expect(service.phase == .failed("The network is not available."))
        #expect(preferences.lastCheckedAt == nil)
    }

    @Test("A failure the user asked for is shown; a background one is not")
    func failureVisibilityFollowsWhoAsked() async throws {
        let (manual, _) = try makeService(latest: { throw FeedUnreachable() })
        manual.checkForUpdates()
        await settle(manual) { if case .failed = $0 { true } else { false } }
        #expect(manual.isShowingSheet)

        let (background, _) = try makeService(latest: { throw FeedUnreachable() })
        background.checkAutomaticallyIfDue()
        await settle(background) { if case .failed = $0 { true } else { false } }
        #expect(!background.isShowingSheet)
    }

    // MARK: Skipping

    @Test("Skipping a version records it and closes the sheet")
    func skippingRecordsTheVersion() async throws {
        let (service, preferences) = try makeService()
        service.checkForUpdates()
        await settle(service) { if case .available = $0 { true } else { false } }

        service.skipCurrentVersion()

        #expect(preferences.skippedVersion == ReleaseVersion("0.11.0"))
        #expect(!service.isShowingSheet)
        #expect(service.phase == .idle)
    }

    @Test("A skipped version is not offered again in the background")
    func skippedVersionStaysQuiet() async throws {
        let (service, preferences) = try makeService()
        preferences.skippedVersion = ReleaseVersion("0.11.0")

        service.checkAutomaticallyIfDue()
        await settle(service) { $0 != .checking }

        #expect(!service.isShowingSheet)
    }

    /// Skipping is about not being interrupted. Somebody who opens the menu and asks is not being
    /// interrupted, so the answer they get has to be current.
    @Test("A manual check still answers after a version was skipped")
    func skippedVersionStillAnswersAManualCheck() async throws {
        let (service, preferences) = try makeService()
        preferences.skippedVersion = ReleaseVersion("0.11.0")

        service.checkForUpdates()
        await settle(service) { $0 != .checking }

        #expect(service.isShowingSheet)
        #expect(service.phase == .available(Self.release("0.11.0")))
        #expect(preferences.skippedVersion == ReleaseVersion("0.11.0"))
    }

    @Test("A manual request promotes a pending skipped automatic release into an offer")
    func manualCheckOverridesAnInFlightSkip() async throws {
        let feed = HeldFeed()
        let (service, preferences) = try makeService(latest: { try await feed.fetch() })
        preferences.skippedVersion = ReleaseVersion("0.11.0")
        service.checkAutomaticallyIfDue()
        await feed.waitForFetch()
        service.checkForUpdates()
        await feed.complete(with: Self.release("0.11.0"))
        await settle(service) { $0 != .checking }
        #expect(service.phase == .available(Self.release("0.11.0")))
        #expect(service.isShowingSheet)
        #expect(await feed.fetchCount == 1)
    }

    @Test("Skipping one version does not skip the next")
    func skipDoesNotCarryForward() async throws {
        let (service, preferences) = try makeService(latest: { UpdateServiceTests.release("0.12.0") })
        preferences.skippedVersion = ReleaseVersion("0.11.0")

        service.checkAutomaticallyIfDue()
        await settle(service) { if case .available = $0 { true } else { false } }

        #expect(service.phase == .available(Self.release("0.12.0")))
        #expect(service.isShowingSheet)
    }
}

@MainActor
@Suite("Update installation lifecycle")
struct UpdateInstallationTests {
    private nonisolated final class DiscardedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [URL] = []
        var count: Int { lock.withLock { files.count } }
        func record(_ file: URL) { lock.withLock { files.append(file) } }
    }

    @MainActor
    private final class Recorder {
        var events: [String] = []
        nonisolated let discardedFiles = DiscardedFiles()
    }

    private nonisolated struct Installer: UpdateInstalling {
        let recorder: Recorder
        let fails: Bool
        var quarantineFails = false
        var verificationFails = false
        func download(_ release: UpdateRelease, onProgress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
            URL(fileURLWithPath: "/fixture/Mimic.pkg")
        }
        func verify(_ fileURL: URL, against release: UpdateRelease) throws {
            #expect(!Thread.isMainThread, "Package verification must leave the update sheet responsive")
            if verificationFails { throw UpdateInstaller.InstallError.notSignedByMimic("Unexpected signer") }
        }
        func stampQuarantine(on fileURL: URL, from release: UpdateRelease) throws {
            if quarantineFails { throw UpdateInstaller.InstallError.quarantineFailed("The file is read-only.") }
        }
        func discard(_ fileURL: URL) { recorder.discardedFiles.record(fileURL) }
        @MainActor func handOff(_ fileURL: URL) async throws {
            #expect(fileURL.path == "/fixture/Mimic.pkg")
            recorder.events.append("handoff")
            if fails { throw UpdateInstaller.InstallError.handoffFailed("Refused") }
        }
    }

    private func readyService(
        fails: Bool = false,
        saveFails: Bool = false,
        backupFails: Bool = false,
        missingStore: Bool = false
    ) async throws -> (UpdateService, Recorder) {
        let recorder = Recorder()
        let defaults = try #require(UserDefaults(suiteName: "UpdateInstallationTests.\(UUID())"))
        let service = UpdateService(
            installedVersion: { ReleaseVersion(major: 0, minor: 10, patch: 0) },
            preferences: UpdatePreferences(defaults: defaults),
            fetchLatestRelease: { UpdateServiceTests.release("0.11.0") },
            installer: Installer(recorder: recorder, fails: fails),
            makeBackup: { _, _ in
                if backupFails { throw CocoaError(.fileWriteOutOfSpace) }
            },
            resolveStoreURL: { missingStore ? nil : URL(fileURLWithPath: "/fixture/mimic.sqlite") },
            flushPendingSave: {
                recorder.events.append("save")
                if saveFails { throw CocoaError(.fileWriteNoPermission) }
            },
            terminate: { recorder.events.append("quit") }
        )
        service.checkForUpdates()
        try await waitUntil { if case .available = service.phase { true } else { false } }
        service.downloadAndPrepare()
        try await waitUntil { if case .readyToInstall = service.phase { true } else { false } }
        return (service, recorder)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Update lifecycle did not settle")
    }

    @Test("Successful handoff waits for actual sheet dismissal before quitting, exactly once")
    func quitWaitsForDismissal() async throws {
        let (service, recorder) = try await readyService()
        service.sheetDidDismiss()
        #expect(recorder.events.isEmpty)
        service.installNow()
        #expect(service.phase.isBusy)
        // Re-entrant actions must neither cancel preparation nor launch a second installer.
        service.installNow()
        service.dismiss()
        service.checkForUpdates()
        service.skipCurrentVersion()
        #expect(service.isShowingSheet)
        try await waitUntil { !service.isShowingSheet }
        #expect(recorder.events == ["save", "handoff"])
        service.sheetDidDismiss()
        service.sheetDidDismiss()
        #expect(recorder.events == ["save", "handoff", "quit"])
        #expect(recorder.discardedFiles.count == 0)
    }

    @Test("A failed handoff never quits or hides the error sheet")
    func failedHandoffDoesNotQuit() async throws {
        let (service, recorder) = try await readyService(fails: true)
        service.installNow()
        try await waitUntil { if case .failed = service.phase { true } else { false } }
        #expect(service.isShowingSheet)
        #expect(!service.phase.isBusy)
        service.dismiss()
        service.sheetDidDismiss()
        #expect(recorder.events == ["save", "handoff"])
        #expect(recorder.discardedFiles.count == 0, "Finder's manual-install fallback still needs the package")
        #expect(service.phase == .idle)
    }

    @Test("A failed save or backup preserves the window and never launches Installer",
          arguments: [true, false])
    func failedPreparationDoesNotInstall(saveFails: Bool) async throws {
        let (service, recorder) = try await readyService(
            saveFails: saveFails, backupFails: !saveFails
        )
        service.installNow()
        try await waitUntil { if case .failed = service.phase { true } else { false } }
        #expect(service.isShowingSheet)
        #expect(recorder.events == ["save"])
        #expect(recorder.discardedFiles.count == 1)
        if !saveFails, case .failed(let message) = service.phase {
            #expect(message.contains("could not back up your projects"))
        }
        service.sheetDidDismiss()
        #expect(recorder.events == ["save"])
    }

    @Test("An unavailable project store prevents installation even after a successful flush")
    func missingStoreDoesNotInstall() async throws {
        let (service, recorder) = try await readyService(missingStore: true)
        service.installNow()
        try await waitUntil { if case .failed = service.phase { true } else { false } }
        #expect(service.isShowingSheet)
        #expect(recorder.events == ["save"])
        #expect(recorder.discardedFiles.count == 1)
        if case .failed(let message) = service.phase {
            #expect(message.contains("could not locate your project store"))
        }
        service.sheetDidDismiss()
        #expect(recorder.events == ["save"])
    }

    @Test("Failed verification or quarantine stamping discards the package and prevents installation",
          arguments: [true, false])
    func failedDownloadPreparation(quarantineFails: Bool) async throws {
        let recorder = Recorder()
        let defaults = try #require(UserDefaults(suiteName: "UpdateQuarantineTests.\(UUID())"))
        let service = UpdateService(
            installedVersion: { ReleaseVersion(major: 0, minor: 10, patch: 0) },
            preferences: UpdatePreferences(defaults: defaults),
            fetchLatestRelease: { UpdateServiceTests.release("0.11.0") },
            installer: Installer(recorder: recorder, fails: false, quarantineFails: quarantineFails,
                                 verificationFails: !quarantineFails),
            makeBackup: { _, _ in },
            terminate: { recorder.events.append("quit") }
        )
        service.checkForUpdates()
        try await waitUntil { if case .available = service.phase { true } else { false } }
        service.downloadAndPrepare()
        try await waitUntil { if case .failed = service.phase { true } else { false } }

        if case .failed(let message) = service.phase {
            #expect(message.contains(quarantineFails ? "macOS security checks" : "not signed by Mimic"))
        } else {
            Issue.record("The failed quarantine stamp did not stop preparation")
        }
        #expect(service.isShowingSheet)
        #expect(recorder.discardedFiles.count == 1)
        service.installNow()
        #expect(recorder.events.isEmpty)
    }

    @Test("Dismissing a prepared update for later never launches or quits")
    func laterDoesNotInstall() async throws {
        let (service, recorder) = try await readyService()
        service.dismiss()
        service.installNow()
        service.sheetDidDismiss()
        try await waitUntil { recorder.discardedFiles.count == 1 }
        #expect(recorder.events.isEmpty)
        #expect(service.phase == .idle)
    }

    @Test("Checking again discards an unused prepared package")
    func newCheckDiscardsPreparedPackage() async throws {
        let (service, recorder) = try await readyService()
        service.checkForUpdates()
        try await waitUntil { recorder.discardedFiles.count == 1 }
        try await waitUntil { if case .available = service.phase { true } else { false } }
        #expect(recorder.events.isEmpty)
    }
}

// MARK: - Verification

@Suite("Installer verification")
struct UpdateInstallerTests {

    private func makeRelease(size: Int, sha256: String) -> UpdateRelease {
        UpdateRelease(
            version: ReleaseVersion("0.11.0")!,
            tag: "v0.11.0",
            title: "Mimic v0.11.0",
            notes: "",
            pageURL: URL(string: "https://example.invalid/releases/v0.11.0")!,
            publishedAt: Date(timeIntervalSince1970: 1_787_420_565),
            asset: .init(
                name: "Mimic-0.11.0.pkg",
                downloadURL: URL(string: "https://example.invalid/Mimic-0.11.0.pkg")!,
                sizeInBytes: size,
                sha256: sha256
            )
        )
    }

    private func makeTinyPackage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-update-verification-\(UUID().uuidString).pkg")
        try Data("abc".utf8).write(to: url)
        return url
    }

    /// Real `pkgutil --check-signature` output, captured from the published Mimic 0.10.0 installer
    /// while running **inside the App Sandbox** — which is where this check actually runs.
    ///
    /// The sandboxed form is the one worth pinning, and it differs from the unsandboxed one in a way
    /// that matters: the `Notarization:` line is absent, because that check needs a path out of the
    /// sandbox that is denied. Anything asserting on notarisation here would pass on a developer's
    /// terminal and fail in the app.
    static let realSandboxedOutput = """
    Package "Mimic-0.10.0.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Signed with a trusted timestamp on: 2026-08-22 17:38:13 +0000
       Certificate Chain:
        1. Developer ID Installer: DEVXA LTD (KW6369JJL9)
           Expires: 2027-02-01 22:12:15 +0000
           SHA256 Fingerprint:
               F0 A3 0C 2E B5 6E 51 FB 9B 44 60 5B ED 02 07 C5 F7 51 A2 99 3A 5E
               E9 87 7A DD 85 95 3B 40 A5 EF
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
        3. Apple Root CA
    """

    @Test("Verification refuses a package whose byte count differs from the release")
    func refusesWrongSize() throws {
        let file = try makeTinyPackage()
        defer { try? FileManager.default.removeItem(at: file) }
        let release = makeRelease(
            size: 4,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        do {
            try UpdateInstaller().verify(file, against: release)
            Issue.record("A 3-byte file was accepted as a 4-byte release")
        } catch let error as UpdateInstaller.InstallError {
            #expect(error == .wrongSize(expected: 4, actual: 3))
        }
    }

    @Test("Verification refuses a package whose SHA-256 differs from the release")
    func refusesWrongChecksum() throws {
        let file = try makeTinyPackage()
        defer { try? FileManager.default.removeItem(at: file) }
        let installer = UpdateInstaller()
        let actual = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let advertised = String(repeating: "0", count: 64)
        let release = makeRelease(size: 3, sha256: advertised)

        #expect(try installer.sha256(of: file) == actual)
        do {
            try installer.verify(file, against: release)
            Issue.record("A package with the wrong checksum was accepted")
        } catch let error as UpdateInstaller.InstallError {
            #expect(error == .checksumMismatch(expected: advertised, actual: actual))
        }
    }

    @Test("The real published installer is recognised")
    func acceptsMimicsOwnSignature() {
        #expect(UpdateInstaller.isSignedByMimic(Self.realSandboxedOutput))
    }

    /// The case a presence check would wave through: a perfectly valid Developer ID signature that
    /// belongs to somebody else.
    @Test("A valid signature from another developer is refused")
    func refusesAnotherDevelopersSignature() {
        let other = Self.realSandboxedOutput
            .replacingOccurrences(of: "DEVXA LTD (KW6369JJL9)", with: "Someone Else Ltd (AB1234CD56)")

        #expect(!UpdateInstaller.isSignedByMimic(other))
    }

    @Test("The team ID in a package name cannot stand in for the signer's team")
    func refusesTeamIDSpoofedInPackageName() {
        let other = """
        Package "Mimic (KW6369JJL9).pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Certificate Chain:
            1. Developer ID Installer: Someone Else Ltd (AB1234CD56)
            2. Developer ID Certification Authority
            3. Apple Root CA
        """

        #expect(!UpdateInstaller.isSignedByMimic(other))
    }

    /// And the mirror of it: our team id appearing somewhere in a package whose chain does not verify.
    @Test("The right team with an invalid status is refused")
    func refusesAnInvalidChain() {
        let unsigned = Self.realSandboxedOutput.replacingOccurrences(
            of: "Status: signed by a developer certificate issued by Apple for distribution",
            with: "Status: no signature"
        )

        #expect(!UpdateInstaller.isSignedByMimic(unsigned))
    }

    @Test("Unsigned output is refused")
    func refusesUnsignedPackages() {
        #expect(!UpdateInstaller.isSignedByMimic("Package \"whatever.pkg\":\n   Status: no signature"))
        #expect(!UpdateInstaller.isSignedByMimic(""))
    }

    /// Pins the identity being checked against, so a change to it is a deliberate edit rather than a
    /// typo that quietly stops matching anything.
    @Test("The pinned team is the one the release script signs with")
    func teamIdentifierIsPinned() {
        #expect(UpdateInstaller.expectedTeamID == "KW6369JJL9")
    }
}

// MARK: - Keeping the unit suite off the real store

@Suite("Unit test store isolation")
struct UnitTestStoreIsolationTests {

    /// The hole this closes: `AppSession.shared` builds the real composition root, one unit test
    /// touches it, and neither of the existing gates — the `-MimicResetForTesting` argument and
    /// `MIMIC_DEFAULTS_SUITE` — is set in a unit test process. Recording which build last opened a
    /// store turned that from a read into a write on the developer's own database.
    @Test("A unit test process is recognised as one")
    func detectsAUnitTestProcess() {
        #expect(UITestSupport.isRunningUnitTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(UITestSupport.isRunningUnitTests(environment: ["XCTestBundlePath": "/tmp/MimicTests.xctest"]))
        #expect(!UITestSupport.isRunningUnitTests(environment: [:]))
        #expect(!UITestSupport.isRunningUnitTests(environment: ["HOME": "/Users/someone"]))
        // And this suite is itself running in one, which is the claim the guard rests on.
        #expect(UITestSupport.isRunningUnitTests())
    }

    @Test("A unit test process gets a store of its own, never the real one")
    func unitTestsGetTheirOwnStore() throws {
        let url = try #require(UITestSupport.unitTestDatabaseURL(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            arguments: []
        ))

        #expect(url.lastPathComponent == "mimic-unittests.sqlite")
        #expect(url.lastPathComponent != "mimic.sqlite")
        // Beside the real store, not inside a bundle.
        #expect(!url.pathComponents.contains { $0.hasSuffix(".app") })
    }

    @Test("It defers to a store the run named for itself")
    func explicitOverrideWins() {
        #expect(UITestSupport.unitTestDatabaseURL(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
                DatabaseFactory.databasePathEnvironmentKey: "/tmp/named.sqlite",
            ],
            arguments: []
        ) == nil)
    }

    @Test("It defers to a UI test run, which has its own store already")
    func uiTestRunWins() {
        #expect(UITestSupport.unitTestDatabaseURL(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration",
                          "MIMIC_DEFAULTS_SUITE": "suite"],
            arguments: []
        ) == nil)
        #expect(UITestSupport.unitTestDatabaseURL(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            arguments: ["-MimicResetForTesting"]
        ) == nil)
    }

    /// Nothing outside a test process may reach it — that is what keeps this out of a shipping path.
    @Test("It is nil for a normally launched app")
    func productionGetsNothing() {
        #expect(UITestSupport.unitTestDatabaseURL(environment: [:], arguments: []) == nil)
    }

    /// The unit suite is hosted *by the app*, so `ContentView` appears and its launch task runs.
    /// Unguarded, every `xcodebuild test` would make a live request to GitHub — and a UI test would
    /// race its own sheet against one the background check raised behind it.
    @Test("No test run checks for updates on its own")
    func testRunsDoNotCheckForUpdates() {
        #expect(UITestSupport.suppressesAutomaticUpdateChecks(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], arguments: []))
        #expect(UITestSupport.suppressesAutomaticUpdateChecks(
            environment: ["MIMIC_DEFAULTS_SUITE": "suite"], arguments: []))
        #expect(UITestSupport.suppressesAutomaticUpdateChecks(
            environment: [:], arguments: ["-MimicResetForTesting"]))
        // And a normally launched app does check.
        #expect(!UITestSupport.suppressesAutomaticUpdateChecks(environment: [:], arguments: []))
        // This process is one of the suppressed kinds, which is the claim the guard rests on.
        #expect(UITestSupport.suppressesAutomaticUpdateChecks())
    }
}
