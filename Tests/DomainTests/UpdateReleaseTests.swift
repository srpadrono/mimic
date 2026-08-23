import Foundation
import Testing
@testable import Domain

/// Decoding the release feed, against a payload GitHub actually returned.
///
/// The fixture below is the real body of
/// `GET /repos/srpadrono/mimic/releases/latest` for v0.10.0, with the release notes shortened and
/// nothing else changed — fields Mimic ignores are kept exactly as they arrive. CONTRIBUTING's
/// "Testing against real inputs" is the reason: three shipped bugs in this repository came from
/// fixtures tidier than reality, and a hand-written payload agrees with whatever the parser expects
/// by construction. Its checksum is the one this project published, and it matches the bytes of the
/// installer in `.artifacts/release` — verified by hand when this test was written.
@Suite("Release feed")
struct UpdateReleaseTests {

    static let realPayload = #"""
{
  "url": "https://api.github.com/repos/srpadrono/mimic/releases/374995582",
  "html_url": "https://github.com/srpadrono/mimic/releases/tag/v0.10.0",
  "id": 374995582,
  "tag_name": "v0.10.0",
  "name": "Mimic v0.10.0 \u2014 a rebuilt workspace, and edits that no longer go missing",
  "draft": false,
  "immutable": false,
  "prerelease": false,
  "created_at": "2026-08-22T17:42:28Z",
  "updated_at": "2026-08-22T17:42:45Z",
  "published_at": "2026-08-22T17:42:45Z",
  "assets": [
    {
      "url": "https://api.github.com/repos/srpadrono/mimic/releases/assets/525281042",
      "id": 525281042,
      "node_id": "RA_kwDOR8LD8c4fTycS",
      "name": "Mimic-0.10.0.pkg",
      "label": "",
      "content_type": "application/octet-stream",
      "state": "uploaded",
      "size": 54618197,
      "digest": "sha256:2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8",
      "download_count": 1,
      "created_at": "2026-08-22T17:42:41Z",
      "updated_at": "2026-08-22T17:42:44Z",
      "browser_download_url": "https://github.com/srpadrono/mimic/releases/download/v0.10.0/Mimic-0.10.0.pkg"
    }
  ],
  "body": "The largest release since the first beta: the workspace was rebuilt, and a family of silent\ndata-loss bugs was closed. Edits you were still typing, edits made while a project was opening, and\nedits made just before you quit could all disappear without an error. They don't now."
}
"""#

    private func decoded() throws -> UpdateRelease {
        try UpdateFeed.decodeLatest(Data(Self.realPayload.utf8))
    }

    // MARK: - The real thing

    @Test("Decodes the payload GitHub returns")
    func decodesARealRelease() throws {
        let release = try decoded()

        #expect(release.version == ReleaseVersion(major: 0, minor: 10, patch: 0))
        #expect(release.tag == "v0.10.0")
        #expect(release.title.hasPrefix("Mimic v0.10.0"))
        #expect(release.pageURL.absoluteString == "https://github.com/srpadrono/mimic/releases/tag/v0.10.0")
        #expect(release.notes.contains("data-loss"))
        // 2026-08-22T17:42:45Z
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_787_420_565))
    }

    @Test("Reads the installer asset, not merely the first one")
    func decodesTheInstallerAsset() throws {
        let asset = try decoded().asset

        #expect(asset.name == "Mimic-0.10.0.pkg")
        #expect(asset.sizeInBytes == 54_618_197)
        #expect(asset.downloadURL.absoluteString
            == "https://github.com/srpadrono/mimic/releases/download/v0.10.0/Mimic-0.10.0.pkg")
        // The prefix is stripped, and the value is the checksum of the published installer.
        #expect(asset.sha256 == "2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8")
    }

    // MARK: - Choosing the asset

    /// "The first asset" is a property of upload order, not of the release.
    @Test("The .pkg is chosen even when other assets come first")
    func picksTheInstallerAmongSeveralAssets() throws {
        let payload = Self.realPayload.replacingOccurrences(
            of: #""assets": ["#,
            with: #""assets": [{"name": "checksums.txt", "state": "uploaded", "size": 96, "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000", "browser_download_url": "https://example.invalid/checksums.txt"}, "#
        )

        let release = try UpdateFeed.decodeLatest(Data(payload.utf8))
        #expect(release.asset.name == "Mimic-0.10.0.pkg")
    }

    @Test("A release with no installer is not an update")
    func refusesAReleaseWithNoInstaller() throws {
        let payload = Self.realPayload.replacingOccurrences(of: "Mimic-0.10.0.pkg", with: "Mimic-0.10.0.zip")

        #expect(throws: UpdateFeed.FeedError.noInstaller(tag: "v0.10.0")) {
            try UpdateFeed.decodeLatest(Data(payload.utf8))
        }
    }

    @Test("An asset that is still uploading is not offered")
    func refusesAnAssetThatIsNotReady() throws {
        let payload = Self.realPayload.replacingOccurrences(of: #""state": "uploaded""#, with: #""state": "starter""#)

        #expect(throws: UpdateFeed.FeedError.assetNotReady(name: "Mimic-0.10.0.pkg", state: "starter")) {
            try UpdateFeed.decodeLatest(Data(payload.utf8))
        }
    }

    // MARK: - The checksum is not optional

    /// The download can only be checked against this, so a release without one is refused outright
    /// rather than installed unverified.
    @Test("A release published without a checksum is refused")
    func refusesAMissingDigest() throws {
        let payload = Self.realPayload.replacingOccurrences(
            of: #""digest": "sha256:2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8","#,
            with: ""
        )

        #expect(throws: UpdateFeed.FeedError.missingDigest(name: "Mimic-0.10.0.pkg")) {
            try UpdateFeed.decodeLatest(Data(payload.utf8))
        }
    }

    @Test("A digest in another algorithm is refused rather than compared as SHA-256")
    func refusesAnUnknownDigestAlgorithm() {
        #expect(UpdateFeed.strippedSHA256("sha256:2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8")
            == "2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8")
        // Uppercase hex normalises, so a comparison against a locally computed digest still matches.
        #expect(UpdateFeed.strippedSHA256("SHA256:2213186B58DC26C199D7948A34694E9EF3965A2A3C429C62B642463B02C299F8")
            == "2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8")
        // A digest that is not SHA-256 would never match, which presents as "every download is
        // corrupt" — a refusal at decode says what is actually wrong.
        #expect(UpdateFeed.strippedSHA256("sha512:abc") == nil)
        #expect(UpdateFeed.strippedSHA256("2213186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8") == nil)
        // Right prefix, wrong length or wrong alphabet.
        #expect(UpdateFeed.strippedSHA256("sha256:2213") == nil)
        #expect(UpdateFeed.strippedSHA256("sha256:zzzz186b58dc26c199d7948a34694e9ef3965a2a3c429c62b642463b02c299f8") == nil)
    }

    // MARK: - Drafts and prereleases

    /// `/releases/latest` filters these out on GitHub's side. Checked anyway: relying on a remote
    /// service's filter for a correctness property is how you discover it changed.
    @Test("A draft or prerelease is refused even if the feed serves one")
    func refusesUnpublishedReleases() throws {
        for field in ["draft", "prerelease"] {
            let payload = Self.realPayload.replacingOccurrences(
                of: #""\#(field)": false"#, with: #""\#(field)": true"#
            )
            #expect(throws: UpdateFeed.FeedError.notPublished(tag: "v0.10.0")) {
                try UpdateFeed.decodeLatest(Data(payload.utf8))
            }
        }
    }

    @Test("A tag that is not a version is refused")
    func refusesAnUnreadableTag() throws {
        let payload = Self.realPayload.replacingOccurrences(of: #""tag_name": "v0.10.0""#, with: #""tag_name": "nightly""#)

        #expect(throws: UpdateFeed.FeedError.malformedVersion("nightly")) {
            try UpdateFeed.decodeLatest(Data(payload.utf8))
        }
    }

    // MARK: - The feed's own constants

    @Test("The feed points at this repository's releases")
    func feedURLIsPinned() {
        #expect(UpdateFeed.latestReleaseURL.absoluteString
            == "https://api.github.com/repos/srpadrono/mimic/releases/latest")
        #expect(UpdateFeed.releasesPageURL.absoluteString
            == "https://github.com/srpadrono/mimic/releases/latest")
    }
}
