import Foundation

/// A release of Mimic that could be installed over this one.
///
/// Everything here comes from the release feed; nothing is inferred. In particular ``asset`` is
/// non-optional, because a release with nothing installable attached is not an update — offering one
/// would produce a button that downloads nothing.
public struct UpdateRelease: Sendable, Equatable, Codable {

    public let version: ReleaseVersion
    /// The git tag, kept as written (`v0.10.0`) so a link built from it resolves.
    public let tag: String
    /// The release's headline.
    public let title: String
    /// The release notes, as Markdown.
    public let notes: String
    /// The page a person is sent to when they would rather read it in a browser.
    public let pageURL: URL
    public let publishedAt: Date
    public let asset: Asset

    /// The installer attached to the release.
    public struct Asset: Sendable, Equatable, Codable {
        public let name: String
        public let downloadURL: URL
        public let sizeInBytes: Int
        /// Lowercase hex SHA-256 of the bytes, with the feed's `sha256:` prefix stripped.
        ///
        /// **Not optional, deliberately.** Every release this project has published carries one, and
        /// it is the only thing the app can check about the file it downloads before handing it to
        /// an installer: a flat `.pkg` cannot be verified in-process the way a bundle can, because
        /// its signature is CMS in the archive header and the API that reads that
        /// (`SecAssessment`) is not in the public SDK. Making this optional would mean a code path
        /// where an unverified installer gets run, and that path would be reached exactly when
        /// something was wrong.
        public let sha256: String

        public init(name: String, downloadURL: URL, sizeInBytes: Int, sha256: String) {
            self.name = name
            self.downloadURL = downloadURL
            self.sizeInBytes = sizeInBytes
            self.sha256 = sha256
        }
    }

    public init(
        version: ReleaseVersion,
        tag: String,
        title: String,
        notes: String,
        pageURL: URL,
        publishedAt: Date,
        asset: Asset
    ) {
        self.version = version
        self.tag = tag
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.asset = asset
    }
}

/// Where Mimic looks for releases, and how it reads what it finds.
///
/// GitHub Releases rather than a hand-maintained appcast: `gh release create` is already the last
/// step of this repository's release process (see CONTRIBUTING, "Releasing"), so the feed is correct
/// the moment a release exists, with nothing extra to remember and no second place to publish. The
/// API also reports each asset's SHA-256, which is what makes the download checkable.
///
/// Pure: this decodes bytes somebody else fetched. Domain does no I/O.
public enum UpdateFeed {

    /// `/releases/latest` excludes drafts and prereleases on GitHub's side, which is the behaviour
    /// wanted here — a draft is not published and a prerelease is not for everyone. The `draft` and
    /// `prerelease` flags are still checked below, because relying on a remote service's filter for
    /// a correctness property is how you find out it changed.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/srpadrono/mimic/releases/latest")!

    /// The page to send someone to when the in-app path cannot be used.
    public static let releasesPageURL = URL(string: "https://github.com/srpadrono/mimic/releases/latest")!

    /// The extension of the one asset Mimic can install.
    ///
    /// Selected by extension rather than by position, because "the first asset" is a property of how
    /// a release happened to be uploaded. A release that also carried a `checksums.txt` would break
    /// a positional reading, and it would break it by offering to install the wrong file.
    public static let installerExtension = "pkg"

    public enum FeedError: Error, Sendable, Equatable, LocalizedError {
        case malformedVersion(String)
        case noInstaller(tag: String)
        case assetNotReady(name: String, state: String)
        case missingDigest(name: String)
        case notPublished(tag: String)

        public var errorDescription: String? {
            switch self {
            case .malformedVersion(let text):
                return "\"\(text)\" is not a version Mimic can compare against its own."
            case .noInstaller(let tag):
                return "Release \(tag) has no .pkg installer attached."
            case let .assetNotReady(name, state):
                return "\(name) is not ready to download yet (\(state))."
            case .missingDigest(let name):
                return "\(name) was published without a checksum, so it cannot be verified."
            case .notPublished(let tag):
                return "Release \(tag) is a draft or a prerelease."
            }
        }
    }

    public static func decodeLatest(_ data: Data) throws -> UpdateRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decode(try decoder.decode(GitHubRelease.self, from: data))
    }

    static func decode(_ release: GitHubRelease) throws -> UpdateRelease {
        guard !release.draft, !release.prerelease else {
            throw FeedError.notPublished(tag: release.tagName)
        }
        guard let version = ReleaseVersion(release.tagName) else {
            throw FeedError.malformedVersion(release.tagName)
        }
        guard version.prerelease.isEmpty else {
            throw FeedError.notPublished(tag: release.tagName)
        }
        guard let asset = release.assets.first(where: {
            ($0.name as NSString).pathExtension.lowercased() == installerExtension
        }) else {
            throw FeedError.noInstaller(tag: release.tagName)
        }
        // An asset still uploading has a URL that resolves and bytes that are incomplete.
        guard asset.state == "uploaded" else {
            throw FeedError.assetNotReady(name: asset.name, state: asset.state)
        }
        guard let digest = asset.digest, let sha256 = strippedSHA256(digest) else {
            throw FeedError.missingDigest(name: asset.name)
        }

        return UpdateRelease(
            version: version,
            tag: release.tagName,
            // A release with no title falls back to its tag rather than to an empty headline.
            title: release.name?.isEmpty == false ? release.name! : release.tagName,
            notes: release.body ?? "",
            pageURL: release.htmlURL,
            publishedAt: release.publishedAt,
            asset: UpdateRelease.Asset(
                name: asset.name,
                downloadURL: asset.browserDownloadURL,
                sizeInBytes: asset.size,
                sha256: sha256
            )
        )
    }

    /// `sha256:2213…` → `2213…`, and `nil` for any other algorithm.
    ///
    /// Refusing an unrecognised algorithm rather than passing the string through: a digest labelled
    /// `sha512:` compared as though it were SHA-256 never matches, which would present as every
    /// download being corrupt.
    static func strippedSHA256(_ digest: String) -> String? {
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        let hex = String(digest.dropFirst(prefix.count)).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

/// The subset of GitHub's release payload Mimic reads.
///
/// Named fields rather than a dictionary so a change in the feed's shape fails at decode with a
/// message, instead of silently becoming a missing update.
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date
    let htmlURL: URL
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let size: Int
        let state: String
        let digest: String?
        let browserDownloadURL: URL
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case publishedAt = "published_at"
        case htmlURL = "html_url"
    }
}

extension GitHubRelease.Asset {
    enum CodingKeys: String, CodingKey {
        case name, size, state, digest
        case browserDownloadURL = "browser_download_url"
    }
}
