import Foundation

/// What a completed update check found.
public enum UpdateCheckOutcome: Sendable, Equatable {
    /// Nothing newer is published — including the case where this build is *ahead* of the feed.
    case upToDate(installed: ReleaseVersion)
    /// A newer release exists and has not been waved away.
    case available(UpdateRelease)
    /// A newer release exists, and this person asked not to be told about this particular one.
    case skipped(UpdateRelease)

    /// The release this outcome is about, whether or not it is being offered.
    public var release: UpdateRelease? {
        switch self {
        case .upToDate: nil
        case .available(let release), .skipped(let release): release
        }
    }

    /// Whether a newer release exists, regardless of whether the window will mention it.
    ///
    /// Skipping is a preference about being interrupted, not a claim about what is published — so a
    /// script asking "is there a newer Mimic?" gets `true` for a skipped release. Conflating the two
    /// would make `mimic app update-check` answer a question nobody asked it.
    public var isNewerReleaseAvailable: Bool {
        switch self {
        case .upToDate: false
        case .available, .skipped: true
        }
    }
}

/// Decides whether a fetched release is worth offering. Pure, and the only place that decides.
public enum UpdateCheck {

    public static func outcome(
        installed: ReleaseVersion,
        latest: UpdateRelease,
        skipping skippedVersion: ReleaseVersion? = nil
    ) -> UpdateCheckOutcome {
        // `<=` rather than `!=`: a build made from a working copy is routinely ahead of the newest
        // release, and offering to "update" it to an older version would be a downgrade presented as
        // an upgrade — the one operation `StoreProvenance` exists to warn about.
        guard latest.version > installed else { return .upToDate(installed: installed) }
        if let skippedVersion, skippedVersion == latest.version { return .skipped(latest) }
        return .available(latest)
    }
}

/// The answer `mimic app update-check` prints, and the payload the HTTP control API returns.
///
/// Versions travel as strings rather than as ``ReleaseVersion`` so the JSON reads the way a person
/// expects — `"installed": "0.10.0"` — and so a caller that has its own idea of version ordering is
/// not forced through this one.
public struct UpdateReport: Codable, Sendable, Equatable {

    /// The version of the running instance.
    public var installed: String
    /// The newest published version.
    public var latest: String
    /// Whether ``latest`` is newer than ``installed``.
    public var updateAvailable: Bool
    /// The release page, for a human following up.
    public var releaseURL: URL
    public var publishedAt: Date
    /// The installer's filename and size, so a script can predict the download.
    public var assetName: String
    public var assetSizeInBytes: Int
    /// The release's headline. The notes themselves are deliberately not here: they are Markdown
    /// measured in kilobytes, and a command that reports a one-line answer should not make a caller
    /// page past them. ``releaseURL`` is where they are read.
    public var title: String

    public init(
        installed: String,
        latest: String,
        updateAvailable: Bool,
        releaseURL: URL,
        publishedAt: Date,
        assetName: String,
        assetSizeInBytes: Int,
        title: String
    ) {
        self.installed = installed
        self.latest = latest
        self.updateAvailable = updateAvailable
        self.releaseURL = releaseURL
        self.publishedAt = publishedAt
        self.assetName = assetName
        self.assetSizeInBytes = assetSizeInBytes
        self.title = title
    }

    public init(installed: ReleaseVersion, outcome: UpdateCheckOutcome, release: UpdateRelease) {
        self.init(
            installed: installed.description,
            latest: release.version.description,
            updateAvailable: outcome.isNewerReleaseAvailable,
            releaseURL: release.pageURL,
            publishedAt: release.publishedAt,
            assetName: release.asset.name,
            assetSizeInBytes: release.asset.sizeInBytes,
            title: release.title
        )
    }
}
