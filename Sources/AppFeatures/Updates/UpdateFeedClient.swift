import Domain
import Foundation

/// Fetches the release feed. The only part of the update flow that talks to the network.
///
/// `nonisolated` rather than inheriting `AppFeatures`' `MainActor` default: this decodes a JSON
/// payload that carries the full release notes, and doing that on the main actor stalls the window
/// for as long as it takes. Nothing here touches UI state — the caller marshals the result back.
nonisolated struct UpdateFeedClient: Sendable {

    enum CheckError: Error, LocalizedError, Equatable {
        case offline(String)
        case rateLimited
        case notFound
        case unexpectedStatus(Int)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .offline(let detail):
                return "Mimic could not reach the release feed. \(detail)"
            case .rateLimited:
                return """
                GitHub is rate-limiting this network for now. Update checks share an hourly \
                allowance with everything else on this connection; it resets within the hour.
                """
            case .notFound:
                return "The release feed did not return a published release."
            case .unexpectedStatus(let code):
                return "The release feed answered with HTTP \(code)."
            case .unreadable(let detail):
                return "Mimic could not read the release feed. \(detail)"
            }
        }
    }

    private let session: URLSession
    private let feedURL: URL
    private let userAgent: String

    init(
        session: URLSession = .shared,
        feedURL: URL = UpdateFeedClient.resolvedFeedURL(),
        userAgent: String = "Mimic/\(ControlAPI.releaseVersion) (macOS; +https://github.com/srpadrono/mimic)"
    ) {
        self.session = session
        self.feedURL = feedURL
        self.userAgent = userAgent
    }

    /// Where the feed is read from, with Debug-only overrides so a test never touches the network.
    ///
    /// Debug-only because these are launch hooks, and this repository's rule is that launch hooks
    /// never ship — a release build reads GitHub and nothing else, so no environment a user's shell
    /// happens to carry can redirect where their updates come from.
    ///
    /// **Two forms, and the resource-name one is the one a UI test must use.** A UI test runner
    /// cannot hand the app a path: the app is sandboxed, so a `file://` URL to anything the runner
    /// wrote is denied, and `MIMIC_IMPORT_FILE` already learned that the hard way — its doc comment
    /// records the two red rounds it cost. So `MIMIC_UPDATE_FEED_FIXTURE` carries a **resource
    /// name** and the app reads it out of its own bundle, where it needs no entitlement, no
    /// container and no home directory. `MIMIC_UPDATE_FEED_URL` stays for driving a running app by
    /// hand during development, where a path is convenient and the sandbox is not in the way because
    /// the file can be put inside the container deliberately.
    static func resolvedFeedURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if DEBUG
        if let fixture = fixtureURL(environment: environment) { return fixture }
        if let override = environment[feedURLEnvironmentKey], !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        #endif
        return UpdateFeed.latestReleaseURL
    }

    #if DEBUG
    /// A bundled feed fixture, resolved through the lookup the import fixtures already use.
    ///
    /// Delegated rather than reimplemented, and the reason is a bug this had before it was: the
    /// built bundle **flattens** `App/Resources`, so a resolver that composes
    /// `Resources/UITestFixtures/<name>` by hand points at a path that does not exist. Every check
    /// then failed as "could not reach the release feed" — including, invisibly, the test asserting
    /// that a release with no installer is refused, which passed while never once exercising the
    /// branch it was written for.
    static func fixtureURL(environment: [String: String]) -> URL? {
        guard let name = environment[feedFixtureEnvironmentKey], !name.isEmpty else { return nil }
        // A resource *name*, never a path: anything with a separator in it is a caller trying to
        // reach outside the bundle, which is the arrangement the sandbox refuses anyway — and
        // `importFixtureURL` would honour it as a path.
        guard !name.contains("/") else { return nil }
        return UITestSupport.importFixtureURL(for: name)
    }

    /// A path, for driving a running app by hand. Not usable from a UI test — see above.
    static let feedURLEnvironmentKey = "MIMIC_UPDATE_FEED_URL"

    /// A resource name under `App/Resources/UITestFixtures/`. What the UI suite uses.
    static let feedFixtureEnvironmentKey = "MIMIC_UPDATE_FEED_FIXTURE"
    #endif

    func latestRelease() async throws -> UpdateRelease {
        var request = URLRequest(url: feedURL)
        // GitHub rejects an unidentified caller, and pinning the media type keeps a future default
        // change on their side from altering the shape this decodes.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // A check nobody asked for must never hold anything up, and a stale cached answer is worse
        // than a slow one when the question is "is there a newer version?".
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CheckError.offline(error.localizedDescription)
        }

        // A `file://` fixture has no HTTPURLResponse, which is what a UI test's feed looks like.
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                break
            case 429:
                throw CheckError.rateLimited
            case 403:
                // GitHub spends 403 on both "you have used your hourly allowance" and genuine
                // refusals, and only the header tells them apart. Reporting the first as the second
                // would send someone hunting for a problem that fixes itself in under an hour.
                throw http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
                    ? CheckError.rateLimited
                    : CheckError.unexpectedStatus(403)
            case 404:
                throw CheckError.notFound
            default:
                throw CheckError.unexpectedStatus(http.statusCode)
            }
        }

        do {
            return try UpdateFeed.decodeLatest(data)
        } catch let error as UpdateFeed.FeedError {
            throw CheckError.unreadable(error.errorDescription ?? "\(error)")
        } catch {
            throw CheckError.unreadable(error.localizedDescription)
        }
    }
}
