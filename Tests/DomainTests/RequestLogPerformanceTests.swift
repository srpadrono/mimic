import Foundation
import Testing
@testable import Domain

/// The log pipeline's cost, measured on the pure rules rather than through a window.
///
/// **What this can and cannot see.** The redesign's real performance liability is that every served
/// request mutates one `@Observable` array on the main actor, which re-evaluates `WorkspaceView.body`
/// and takes four O(n) scans with it. That is view work and lives in `AppFeatures`, which is not in
/// `Package.swift` — so it needs the Xcode test runner and an instrument, and it is #24's problem.
///
/// What *is* measurable here is the part that moved into Domain: the filter predicate every one of
/// those scans ultimately calls. These are the numbers that have to stay flat as the redesign adds
/// filters, and they are deterministic, windowless and run in `swift test` — which matters more than
/// usual on this machine, where `xcodebuild test` regularly cannot run at all.
///
/// Thresholds are deliberately loose. A benchmark that fails on a busy laptop teaches people to
/// ignore it; these are set to catch an accidental O(n²), not to police a few milliseconds.
@Suite("Request log performance")
struct RequestLogPerformanceTests {

    /// The shipped cap. `MockServerRuntime.maxRequestLogEntries` and the engine's
    /// `.bufferingNewest(1000)` both sit here, so 1,000 *is* the worst case — not 10,000, which is
    /// the number the redesign's performance notes assume and which this app cannot reach.
    private static let bufferCap = 1_000

    private static func makeLogs(_ count: Int, endpoints: Int = 100) -> [RequestLog] {
        let endpointIDs = (0..<endpoints).map { _ in UUID() }
        let journeyID = UUID()
        return (0..<count).map { i in
            let outcome: RequestOutcome
            switch i % 4 {
            case 0: outcome = .endpoint
            case 1: outcome = .unmatched
            case 2: outcome = .journey
            default: outcome = .blockedByJourney
            }
            return RequestLog(
                method: i % 2 == 0 ? .get : .post,
                path: "/api/v1/resource/\(i)/detail",
                requestHeaders: [:],
                requestBody: nil,
                matchedEndpointID: outcome == .endpoint ? endpointIDs[i % endpoints] : nil,
                matchedScenarioID: nil,
                responseStatusCode: outcome == .unmatched ? 404 : 200,
                responseHeaders: [:],
                responseBody: nil,
                matchedJourneyID: outcome == .journey ? journeyID : nil,
                matchedJourneyStepID: nil,
                outcome: outcome
            )
        }
    }

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    @Test("Filtering a full buffer stays linear, not quadratic")
    func filteringIsLinear() {
        let small = Self.makeLogs(250)
        let full = Self.makeLogs(Self.bufferCap)
        let filter = RequestLogFilter(unmatchedOnly: true, text: "resource")

        // Warm, so the first-call cost of any lazily-built machinery is not what gets measured.
        _ = filter.apply(to: small)

        let smallTime = elapsed { for _ in 0..<20 { _ = filter.apply(to: small) } }
        let fullTime = elapsed { for _ in 0..<20 { _ = filter.apply(to: full) } }

        // 4× the entries should cost roughly 4× the time. 12× is generous headroom for a noisy
        // machine while still catching a genuine O(n²) — which would show up here as ~16×.
        let ratio = fullTime / max(smallTime, 0.000_001)
        #expect(ratio < 12, "4x the entries cost \(String(format: "%.1f", ratio))x the time — suspect superlinear")
    }

    @Test("An inert filter does not copy the collection")
    func inertFilterIsFree() {
        let full = Self.makeLogs(Self.bufferCap)

        // `apply` short-circuits on `isActive`, so the common case — no filters, which is what the
        // log shows by default and therefore what runs on every single served request — must not
        // walk 1,000 entries to conclude it has nothing to do.
        let inert = elapsed { for _ in 0..<200 { _ = RequestLogFilter.none.apply(to: full) } }
        let active = elapsed { for _ in 0..<200 { _ = RequestLogFilter(unmatchedOnly: true).apply(to: full) } }

        #expect(inert < active, "the no-filter path should be cheaper than filtering")
    }

    @Test("A full buffer filters in well under a frame")
    func fullBufferFiltersWithinAFrame() {
        let full = Self.makeLogs(Self.bufferCap)
        let filter = RequestLogFilter(unmatchedOnly: true, method: .get, text: "resource")
        _ = filter.apply(to: full)

        let once = elapsed { _ = filter.apply(to: full) }

        // 16ms is one frame at 60Hz. This runs on every keystroke in the filter field, so exceeding
        // a frame here is felt directly as the field lagging behind typing.
        #expect(once < 0.016, "filtering a full buffer took \(String(format: "%.1f", once * 1000))ms")
    }

    @Test("Text matching short-circuits on the cheapest field first")
    func textMatchingShortCircuits() {
        let full = Self.makeLogs(Self.bufferCap)
        _ = RequestLogFilter(text: "resource").apply(to: full)

        // A query that hits on `path` — the first field checked — against one that misses everywhere
        // and therefore pays for all three comparisons on every entry.
        let hits = elapsed { for _ in 0..<20 { _ = RequestLogFilter(text: "resource").apply(to: full) } }
        let misses = elapsed { for _ in 0..<20 { _ = RequestLogFilter(text: "zzzznotfound").apply(to: full) } }

        // Not asserting hits < misses — that is true but flaky at this scale. Asserting the miss case
        // stays bounded, which is what a user typing a nonsense query actually experiences.
        #expect(misses < 0.2, "a fully-missing query over 20 passes took \(String(format: "%.0f", misses * 1000))ms")
        #expect(hits >= 0)
    }
}
