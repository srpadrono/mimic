import Testing
import Foundation
@testable import Domain

@Suite("Release versions")
struct ReleaseVersionTests {

    // MARK: - The comparison the updater rests on

    /// The negative control this type exists for.
    ///
    /// Every pair below is one that **string comparison gets wrong**, and each is written as two
    /// literals so the test cannot be satisfied by whatever `ReleaseVersion` happens to do. Revert
    /// `<` to a `description` comparison and this goes red on the first case; that is the whole
    /// point of listing them separately from the ordinary ordering cases.
    @Test("Versions string comparison would order backwards")
    func doubleDigitComponentsOrderNumerically() throws {
        let backwardsUnderStringComparison: [(String, String)] = [
            ("0.9.9", "0.9.10"),
            ("0.9.2", "0.10.0"),
            ("1.9.0", "1.10.0"),
            ("0.2.0", "0.10.0"),
            ("9.0.0", "10.0.0"),
        ]
        for (lower, higher) in backwardsUnderStringComparison {
            let low = try #require(ReleaseVersion(lower))
            let high = try #require(ReleaseVersion(higher))
            #expect(low < high, "\(lower) should be older than \(higher)")
            #expect(!(high < low), "\(higher) should not be older than \(lower)")
            // The string order really is the opposite, which is what makes these cases worth having.
            #expect(higher < lower, "this pair is only interesting while strings order it backwards")
        }
    }

    @Test("Ordinary ordering")
    func ordersByMajorThenMinorThenPatch() throws {
        let ascending = ["0.1.0", "0.9.3", "0.10.0", "1.0.0", "1.0.1", "1.2.0", "2.0.0"]
            .map { ReleaseVersion($0) }
        let versions = try ascending.map { try #require($0) }
        #expect(versions == versions.sorted())
    }

    @Test("A version equals itself however it is spelled")
    func acceptsBothSpellingsThisRepositoryProduces() throws {
        // The tag is `v0.10.0`; CFBundleShortVersionString is `0.10.0`. The updater compares one
        // against the other on every check, so they must parse to the same value.
        #expect(ReleaseVersion("v0.10.0") == ReleaseVersion("0.10.0"))
        #expect(ReleaseVersion("V0.10.0") == ReleaseVersion("0.10.0"))
        #expect(ReleaseVersion(" 0.10.0 ") == ReleaseVersion("0.10.0"))
        // Build metadata is not part of the version's identity in SemVer.
        #expect(ReleaseVersion("0.10.0+build.5") == ReleaseVersion("0.10.0"))
        // A missing patch is zero, not missing.
        #expect(ReleaseVersion("0.10") == ReleaseVersion("0.10.0"))
    }

    // MARK: - Prereleases

    @Test("A prerelease precedes the release it leads to")
    func prereleaseSortsBelowItsRelease() throws {
        let beta = try #require(ReleaseVersion("0.11.0-beta.1"))
        let release = try #require(ReleaseVersion("0.11.0"))
        #expect(beta < release)
        #expect(!(release < beta))

        // …and above the release before it, so a beta is still an upgrade from 0.10.0.
        let previous = try #require(ReleaseVersion("0.10.0"))
        #expect(previous < beta)
    }

    @Test("Prerelease identifiers compare by SemVer rules")
    func prereleaseIdentifiersCompareNumericallyThenLexically() throws {
        let ascending = ["0.11.0-alpha", "0.11.0-alpha.1", "0.11.0-alpha.2", "0.11.0-alpha.10",
                         "0.11.0-alpha.beta", "0.11.0-beta", "0.11.0"]
        let versions = try ascending.map { try #require(ReleaseVersion($0)) }
        #expect(versions == versions.sorted())
    }

    // MARK: - What must not parse

    @Test("Numeric prerelease identifiers remain numeric beyond Int.max")
    func arbitrarilyLargePrereleaseNumbers() throws {
        let lower = try #require(ReleaseVersion("1.0.0-99999999999999999999"))
        let higher = try #require(ReleaseVersion("1.0.0-100000000000000000000"))
        let alphabetic = try #require(ReleaseVersion("1.0.0-alpha"))
        let digitPrefixed = try #require(ReleaseVersion("1.0.0-0alpha"))
        #expect(lower < higher)
        #expect(higher < alphabetic)
        #expect(higher < digitPrefixed)
    }

    @Test("Prerelease and build suffixes reject malformed identifiers", arguments: [
        "1.2.3+", "1.2.3+build..1", "1.2.3+build+1", "1.2.3+build_1",
        "1.2.3-beta_1", "1.2.3-beta 1", "1.2.3-β", "1.2.3-01", "01.2.3",
    ])
    func malformedSuffixes(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test("Build identifiers allow leading zeros and hyphens")
    func acceptsValidBuildIdentifiers() throws {
        let version = try #require(ReleaseVersion("1.2.3-beta.1+001.build-info"))
        #expect(version.description == "1.2.3-beta.1")
    }

    /// Unreadable input must stay unreadable.
    ///
    /// The tempting alternative — defaulting to `0.0.0` — is the dangerous one: `0.0.0` is older
    /// than every real release, so a manifest the app cannot read would present as a permanent
    /// "update available" pointing at nothing.
    @Test("Malformed versions return nil rather than a default")
    func refusesWhatItCannotRead() {
        for text in ["", "   ", "v", "latest", "1.2.3.4", "1..2", "1.x.0", "-1.2.0", "1.+2.0",
                     "0.10.0-", "0.10.0-beta..1", "０.１.０"] {
            #expect(ReleaseVersion(text) == nil, "\"\(text)\" should not parse")
        }
    }

    // MARK: - Wire format

    @Test("Round-trips as a plain string")
    func codesAsAString() throws {
        let version = try #require(ReleaseVersion("0.11.0-beta.1"))
        let data = try JSONEncoder().encode(version)
        #expect(String(decoding: data, as: UTF8.self) == "\"0.11.0-beta.1\"")
        #expect(try JSONDecoder().decode(ReleaseVersion.self, from: data) == version)
    }

    @Test("Decoding refuses a version it cannot read")
    func decodingRejectsMalformedText() {
        let data = Data("\"not-a-version\"".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReleaseVersion.self, from: data)
        }
    }

    // MARK: - The versions this build actually carries

    /// Pins the two constants the updater compares, so the release checklist cannot half-happen.
    ///
    /// `Scripts/package_release.sh` already fails a release when `MARKETING_VERSION` and
    /// `ControlAPI.releaseVersion` disagree. This asserts the surviving half is a version at all —
    /// a `releaseVersion` that stopped parsing would disable update checks silently.
    @Test("The shipped release version parses")
    func shippedVersionIsReadable() throws {
        let version = try #require(ReleaseVersion(ControlAPI.releaseVersion))
        #expect(version.description == ControlAPI.releaseVersion)
    }
}
