import Domain
import Foundation
import Observation

/// Where the flow is. Exhaustive: the sheet renders from this and nothing else.
public enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate(installed: ReleaseVersion)
    case available(UpdateRelease)
    case downloading(UpdateRelease, fraction: Double)
    case readyToInstall(UpdateRelease, installer: URL)
    case installing(UpdateRelease)
    case failed(String)

    public var release: UpdateRelease? {
        switch self {
        case .idle, .checking, .upToDate, .failed: nil
        case .available(let release),
             .downloading(let release, _),
             .readyToInstall(let release, _), .installing(let release): release
        }
    }

    /// Whether closing the sheet now would abandon work in progress.
    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        case .idle, .upToDate, .available, .readyToInstall, .failed: false
        }
    }
}

/// What the update sheet needs from the app: where the flow is, and the actions its buttons take.
///
/// `UpdateService` is the one production conformer. The sheet reads through this protocol so it can
/// be drawn in the gallery and in tests from a fixture, without a feed, a download or an installer.
@MainActor
public protocol UpdateSheetModel: AnyObject, Observable {
    var phase: UpdatePhase { get }
    var installedVersionDescription: String { get }
    var checksAutomatically: Bool { get set }
    func checkForUpdates()
    func skipCurrentVersion()
    func dismiss()
    func downloadAndPrepare()
    func installNow()
}

#if DEBUG
/// An update flow with no feed behind it, for the gallery, previews and tests. Its buttons move
/// between phases the way the real flow would, without downloading anything.
@MainActor
@Observable
public final class UpdateSheetPreviewModel: UpdateSheetModel {
    public var phase: UpdatePhase
    public var installedVersionDescription: String
    public var checksAutomatically = true

    public init(phase: UpdatePhase = .available(UpdateSheetPreviewModel.release),
                installedVersionDescription: String = "1.9") {
        self.phase = phase
        self.installedVersionDescription = installedVersionDescription
    }

    /// The release the design's update sheet announces.
    public static let release = UpdateRelease(
        version: ReleaseVersion(major: 1, minor: 10, patch: 0),
        tag: "v1.10.0",
        title: "Mimic 1.10",
        notes: """
        ## New
        - Journeys can drop a connection after a delay, to test timeouts.
        - Copy any logged request as a cURL command.

        ## Fixed
        - The request log keeps its column widths between launches.
        - Importing a HAR with duplicate routes no longer skips the first response.
        """,
        pageURL: URL(fileURLWithPath: "/"),
        publishedAt: Date(timeIntervalSinceReferenceDate: 812_000_000),
        asset: UpdateRelease.Asset(
            name: "Mimic-1.10.0.zip",
            downloadURL: URL(fileURLWithPath: "/Mimic-1.10.0.zip"),
            sizeInBytes: 18_000_000,
            sha256: String(repeating: "0", count: 64)
        )
    )

    public func checkForUpdates() { phase = .available(Self.release) }
    public func skipCurrentVersion() { phase = .idle }
    public func dismiss() { phase = .idle }
    public func downloadAndPrepare() { phase = .downloading(Self.release, fraction: 0.4) }
    public func installNow() { phase = .installing(Self.release) }
}
#endif
