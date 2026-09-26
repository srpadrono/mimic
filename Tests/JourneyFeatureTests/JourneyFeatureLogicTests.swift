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

    @Test("Capture preview refuses requests without an HTTP response")
    func capturePreviewExplainsTransportFailures() {
        let logs = [
            RequestLog(method: .get, path: "/account", responseStatusCode: nil, outcome: .endpoint),
            RequestLog(method: .get, path: "/account", responseStatusCode: nil, outcome: .proxyFailure),
        ]
        for log in logs {
            let capture = CaptureJourneySheet.Capture(logs: [log], suggestedName: "Account flow")
            #expect(capture.stepCount == 0)
            #expect(capture.refusal != nil)
            #expect(capture.summary == capture.refusal)
            #expect(!capture.summary.contains("one step, reproducing"))
        }
        #expect(CaptureJourneySheet.Capture(logs: [logs[0]], suggestedName: "Account flow").refusal
                == "This request has no HTTP response to capture. Add a connection-drop or timeout step to reproduce a transport failure.")
        #expect(CaptureJourneySheet.Capture(logs: [logs[1]], suggestedName: "Account flow").refusal
                == "The backend did not return a complete response.")
    }

    @Test("Capture preview explains skipped journey traffic separately from repeated responses")
    func capturePreviewCountsActualSteps() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let logs = [
            RequestLog(timestamp: start, method: .get, path: "/poll", responseStatusCode: 202, outcome: .endpoint),
            RequestLog(timestamp: start.addingTimeInterval(1), method: .get, path: "/poll", responseStatusCode: 202, outcome: .endpoint),
            RequestLog(timestamp: start.addingTimeInterval(2), method: .get, path: "/scripted", responseStatusCode: 200, outcome: .journey),
        ]
        let capture = CaptureJourneySheet.Capture(logs: logs, suggestedName: "Poll flow")
        #expect(capture.refusal == nil)
        #expect(capture.stepCount == 1)
        #expect(capture.summary == "Captures 2 requests in the order they arrived, as 1 step. Requests already answered by a journey are excluded. Consecutive identical responses become one step that repeats.")

        let scriptedOnly = CaptureJourneySheet.Capture(logs: [logs[2]], suggestedName: "Scripted flow")
        #expect(scriptedOnly.stepCount == 0)
        #expect(scriptedOnly.refusal == "No new steps can be captured. Select requests that were not already answered by a journey.")
    }

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
    /// The parser is tolerant for callers that use it directly. The sheet checks
    /// `firstInvalidHeaderLine` before parsing so user-entered lines are never silently lost.
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

    @Test("The sheet identifies the first malformed header instead of silently losing it")
    func findsMalformedHeaderLine() {
        #expect(JourneyStepSheet.firstInvalidHeaderLine("X-Trace: abc\nRetry-After 30") == 2)
        #expect(JourneyStepSheet.firstInvalidHeaderLine("\n: 30\nX-Trace: abc") == 2)
        #expect(JourneyStepSheet.firstInvalidHeaderLine("\nX-Trace: abc\nLocation: https://example.com:8443") == nil)
        #expect(JourneyStepSheet.firstInvalidHeaderLine("X-Trace: abc\r\nRetry-After 30") == 2)
    }

    @Test("An ASCII colon separates a header even when followed by a combining mark")
    func preservesUnicodeHeaderValues() {
        let source = "X-Note:\u{0301}value"
        #expect(JourneyStepSheet.firstInvalidHeaderLine(source) == nil)
        let headers = JourneyStepSheet.parseHeaders(source)
        #expect(headers == ["X-Note": "\u{0301}value"])
        #expect(Array((headers["X-Note"] ?? "").utf8) == [0xCC, 0x81, 0x76, 0x61, 0x6C, 0x75, 0x65])
    }

    @Test("Wait fields allow gradual repair of legacy excessive values", arguments: [
        ("300000", nil, 300_000),
        ("300001", nil, nil),
        ("500000", 500_000, 500_000),
        ("400000", 500_000, 400_000),
        ("500001", 500_000, nil),
        ("300001", 300_000, nil),
        ("-1", 500_000, nil),
        ("abc", 500_000, nil),
        ("0", 500_000, 0),
    ] as [(String, Int?, Int?)])
    func validatesEditedWait(text: String, existing: Int?, expected: Int?) {
        #expect(JourneyStepSheet.validatedWaitValue(text, existingValue: existing) == expected)
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
