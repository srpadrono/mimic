import Foundation
import Testing
@testable import Domain

@Suite("Update check")
struct UpdateCheckTests {

    private func release(_ version: String) -> UpdateRelease {
        UpdateRelease(
            version: ReleaseVersion(version)!,
            tag: "v\(version)",
            title: "Mimic v\(version)",
            notes: "Notes.",
            pageURL: URL(string: "https://github.com/srpadrono/mimic/releases/tag/v\(version)")!,
            publishedAt: Date(timeIntervalSince1970: 1_787_420_565),
            asset: UpdateRelease.Asset(
                name: "Mimic-\(version).pkg",
                downloadURL: URL(string: "https://example.invalid/Mimic-\(version).pkg")!,
                sizeInBytes: 54_618_197,
                sha256: String(repeating: "a", count: 64)
            )
        )
    }

    private func version(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }

    // MARK: - Offering

    @Test("A newer release is offered")
    func newerReleaseIsAvailable() {
        let outcome = UpdateCheck.outcome(installed: version("0.10.0"), latest: release("0.11.0"))

        #expect(outcome == .available(release("0.11.0")))
        #expect(outcome.isNewerReleaseAvailable)
    }

    @Test("The release you are already running is not an update")
    func sameVersionIsUpToDate() {
        let outcome = UpdateCheck.outcome(installed: version("0.10.0"), latest: release("0.10.0"))

        #expect(outcome == .upToDate(installed: version("0.10.0")))
        #expect(!outcome.isNewerReleaseAvailable)
        #expect(outcome.release == nil)
    }

    /// A build made from a working copy is routinely ahead of the newest release.
    ///
    /// Comparing with `!=` instead of `>` would offer that developer a "newer" version that is
    /// older than what they are running — a downgrade, presented as an upgrade, which is the exact
    /// operation `StoreProvenance` exists to warn about after the fact.
    @Test("A build ahead of the feed is not offered a downgrade")
    func localBuildAheadOfTheFeedIsUpToDate() {
        let outcome = UpdateCheck.outcome(installed: version("0.11.0"), latest: release("0.10.0"))

        #expect(outcome == .upToDate(installed: version("0.11.0")))
        #expect(!outcome.isNewerReleaseAvailable)
    }

    /// The comparison a string would get backwards, through the real decision function.
    @Test("0.10.0 is newer than 0.9.10")
    func comparesVersionsNumerically() {
        #expect(UpdateCheck.outcome(installed: version("0.9.10"), latest: release("0.10.0"))
            .isNewerReleaseAvailable)
        #expect(!UpdateCheck.outcome(installed: version("0.10.0"), latest: release("0.9.10"))
            .isNewerReleaseAvailable)
    }

    // MARK: - Skipping

    @Test("A skipped version is found but not offered")
    func skippedVersionIsNotOffered() {
        let outcome = UpdateCheck.outcome(
            installed: version("0.10.0"),
            latest: release("0.11.0"),
            skipping: version("0.11.0")
        )

        #expect(outcome == .skipped(release("0.11.0")))
        #expect(outcome.release != nil)
    }

    /// Skipping is a preference about being interrupted, not a claim about what is published.
    ///
    /// If these were conflated, `mimic app update-check` would answer "no update" to a machine
    /// because a person once dismissed a dialog.
    @Test("A skipped version still counts as available to a caller asking what is published")
    func skippingDoesNotChangeWhatIsPublished() {
        let outcome = UpdateCheck.outcome(
            installed: version("0.10.0"),
            latest: release("0.11.0"),
            skipping: version("0.11.0")
        )

        #expect(outcome.isNewerReleaseAvailable)
    }

    @Test("Skipping one version does not skip the next")
    func skipAppliesToOneVersionOnly() {
        let outcome = UpdateCheck.outcome(
            installed: version("0.10.0"),
            latest: release("0.12.0"),
            skipping: version("0.11.0")
        )

        #expect(outcome == .available(release("0.12.0")))
    }

    // MARK: - The report a script reads

    @Test("The report carries both versions and the verdict")
    func reportDescribesTheOutcome() {
        let latest = release("0.11.0")
        let outcome = UpdateCheck.outcome(installed: version("0.10.0"), latest: latest)

        let report = UpdateReport(installed: version("0.10.0"), outcome: outcome, release: latest)

        #expect(report.installed == "0.10.0")
        #expect(report.latest == "0.11.0")
        #expect(report.updateAvailable)
        #expect(report.assetName == "Mimic-0.11.0.pkg")
        #expect(report.assetSizeInBytes == 54_618_197)
        #expect(report.title == "Mimic v0.11.0")
        #expect(report.releaseURL == latest.pageURL)
    }

    @Test("An up-to-date report still names the release it compared against")
    func reportOnAnUpToDateInstance() {
        let latest = release("0.10.0")
        let outcome = UpdateCheck.outcome(installed: version("0.10.0"), latest: latest)

        let report = UpdateReport(installed: version("0.10.0"), outcome: outcome, release: latest)

        #expect(!report.updateAvailable)
        #expect(report.installed == report.latest)
    }

    @Test("The report round-trips as JSON")
    func reportIsCodable() throws {
        let latest = release("0.11.0")
        let report = UpdateReport(
            installed: version("0.10.0"),
            outcome: UpdateCheck.outcome(installed: version("0.10.0"), latest: latest),
            release: latest
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(report)
        #expect(try decoder.decode(UpdateReport.self, from: data) == report)
    }

    /// The result envelope has to carry the payload, or the command answers with nothing.
    @Test("A ControlResult can carry an update report")
    func controlResultCarriesTheReport() throws {
        let latest = release("0.11.0")
        let report = UpdateReport(
            installed: version("0.10.0"),
            outcome: .available(latest),
            release: latest
        )

        let result = ControlResult(update: report)
        #expect(result.update == report)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ControlResult.self, from: try encoder.encode(result))
        #expect(restored.update?.latest == "0.11.0")
    }
}
