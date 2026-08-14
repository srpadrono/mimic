import Foundation
import Testing
import Domain
@testable import AppFeatures

/// The journey feature's pure logic — which is, deliberately, a short list.
///
/// Almost everything this feature derives is `private` to a view: the run controls' progress line,
/// the navigator row's step count, the capture sheet's summary sentence and the template picker's
/// pluralisation are all private computed properties, so they cannot be called from here and are
/// pinned by geometry in `JourneyFeatureRenderingTests` instead. What *is* reachable is the two
/// static helpers, and both of them turn user input or user-facing text into a value — which is
/// exactly the kind of thing worth asserting on directly.
@Suite("JourneyFeature Logic")
@MainActor
struct JourneyFeatureLogicTests {

    // MARK: - Header parsing

    @Test("A header line is split at its first colon, so a value may contain more of them")
    func parsesOneHeaderPerLine() {
        let headers = JourneyStepSheet.parseHeaders("""
        Retry-After: 30
        Location: https://example.com:8443/orders?id=7
        """)

        #expect(headers == [
            "Retry-After": "30",
            "Location": "https://example.com:8443/orders?id=7",
        ])
    }

    /// The field is free text in a sheet, so every one of these lines is something a user will type.
    ///
    /// A line with no colon and a line with an empty name are both dropped rather than stored under
    /// `""`: a header named nothing is not a header, and the alternative is a step that serves a
    /// response with a nameless field in it.
    @Test("Blank lines, lines with no colon, and lines with no name are dropped")
    func ignoresLinesThatAreNotHeaders() {
        let headers = JourneyStepSheet.parseHeaders("""
        X-Trace: abc

        not a header at all
        : 30
          Retry-After  :   30
        """)

        #expect(headers == ["X-Trace": "abc", "Retry-After": "30"])
        #expect(JourneyStepSheet.parseHeaders("") == [:])
    }

    /// A dictionary, so the same name twice keeps the last one — worth stating because it is a real
    /// limit rather than an oversight: a step cannot script two `Set-Cookie` headers, and the field
    /// accepts the text that looks as though it can.
    @Test("The same header name twice keeps the last value")
    func lastDuplicateWins() {
        #expect(
            JourneyStepSheet.parseHeaders("Set-Cookie: a=1\nSet-Cookie: b=2")
                == ["Set-Cookie": "b=2"]
        )
    }

    /// The sheet parses the text it writes.
    ///
    /// Opening an existing step renders its headers as sorted `Name: Value` lines and the save path
    /// parses them back, so the two halves have to agree on one format or editing a step silently
    /// rewrites its headers. The rendering half is private to the sheet, so the format is spelled out
    /// here the way `loadExistingStep` spells it; if that ever stops being what `parseHeaders`
    /// accepts, this is the test that says so.
    @Test("Headers survive the round trip the step editor puts them through")
    func roundTripsTheFormatTheEditorWrites() {
        let original = [
            "Retry-After": "30",
            "X-Trace": "abc-123",
            "Link": "</next>; rel=\"next\"",
        ]
        let asEdited = original
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")

        #expect(JourneyStepSheet.parseHeaders(asEdited) == original)
    }

    // MARK: - Failure labels

    /// The step row's own words for a transport failure, which are not the run report's.
    ///
    /// `JourneyStepProgress.failureLabel` spells the same two outcomes `connection-drop` and
    /// `timeout(30000ms)` — machine labels, for the CLI and the request log. The row is prose in a
    /// column that has to survive a 300pt centre pane, so it says "drop" and "timeout 30000ms". The
    /// two are separate on purpose; asserting the row's exactly is what keeps them from being
    /// quietly merged.
    @Test("A failing step is described in the words the row shows")
    func describesFailuresForTheRow() {
        #expect(JourneyStepRow.failureText(.connectionDrop) == "drop")
        #expect(
            JourneyStepRow.failureText(.timeout(holdMs: NetworkFailure.defaultTimeoutHoldMs))
                == "timeout 30000ms"
        )
    }

    /// The string is unbounded, and the row is built around that fact.
    ///
    /// A hold is whatever millisecond count somebody typed, so this label runs from four characters
    /// to eleven with no separators to shorten it — which is why the row must leave it compressible
    /// and truncatable. An hour-long hold is the case the row's 300pt preview exists for.
    @Test("A long hold produces a long label, with no grouping to shorten it")
    func doesNotGroupDigitsInAHold() {
        #expect(JourneyStepRow.failureText(.timeout(holdMs: 3_600_000)) == "timeout 3600000ms")
        #expect(JourneyStepRow.failureText(.timeout(holdMs: 0)) == "timeout 0ms")
    }
}
