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
