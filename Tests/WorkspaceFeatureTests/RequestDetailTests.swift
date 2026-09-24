import SwiftUI
import Testing
import Domain
import DesignSystem
@testable import AppFeatures

@Suite("Request detail formatting")
struct RequestDetailTests {

    // MARK: - Search highlighting

    @Test("Every occurrence is counted, case-insensitively")
    func countsSearchMatches() {
        var text = AttributedString("Alpha beta ALPHA gamma alpha")

        #expect(RequestBodyView.highlight("alpha", in: &text) == 3)
    }

    @Test("An empty search term matches nothing rather than everything")
    func emptySearchTermIsInert() {
        // Guarding this is not cosmetic: `range(of: "")` succeeds at every index, so without it the
        // highlight loop never advances and the view hangs.
        var text = AttributedString("some body")

        #expect(RequestBodyView.highlight("", in: &text) == 0)
    }

    @Test("A body over the formatting limit is shown verbatim")
    func skipsFormattingForHugeBodies() {
        let huge = "{\"a\":\"" + String(repeating: "x", count: JSONFormatter.formattingLimit) + "\"}"
        let rendered = RequestBodyView.render(payload: huge, searchText: "")

        #expect(rendered.isFormatted == false)
        #expect(String(rendered.text.characters) == huge)
    }

    @Test("A small body stays verbatim when its formatted expansion exceeds the budget")
    func rejectedFormatterExpansionStaysVerbatim() {
        // This is only 701 bytes at input, so RequestBodyView passes it to JSONFormatter.
        // The formatter's indentation would expand the truncated nesting far past a normal body.
        let truncated = String(repeating: "[", count: 700) + "0"
        #expect(truncated.utf8.count == 701)

        let rendered = RequestBodyView.render(payload: truncated, searchText: "")
        #expect(rendered.isFormatted == false)
        #expect(String(rendered.text.characters) == truncated)
    }

    @Test("A normal body is formatted and match-counted together")
    func rendersFormattedBodyWithMatches() {
        let rendered = RequestBodyView.render(payload: #"{"id":1,"id2":2}"#, searchText: "id")

        #expect(rendered.isFormatted)
        #expect(String(rendered.text.characters).contains("\n"))
        #expect(rendered.matchCount == 2)
    }

    @Test("Match summary reads as a sentence")
    func matchSummaryWording() {
        #expect(RequestBodyView.matchSummary(0) == "No matches in this body")
        #expect(RequestBodyView.matchSummary(1) == "1 match")
        #expect(RequestBodyView.matchSummary(4) == "4 matches")
    }

    // MARK: - cURL export

    @Test("A logged request becomes a runnable curl command")
    func buildsCurlCommand() {
        let log = RequestLog(
            method: .post,
            path: "/api/users?dry=true",
            requestHeaders: ["Content-Type": "application/json", "Authorization": "Bearer abc"],
            requestBody: #"{"name":"Ada"}"#,
            responseStatusCode: 201
        )

        let command = RequestLogExport.curl(for: log, port: 8080)

        #expect(command.hasPrefix("curl -X POST 'http://localhost:8080/api/users?dry=true'"))
        #expect(command.contains("-H 'Authorization: Bearer abc'"))
        #expect(command.contains("-H 'Content-Type: application/json'"))
        #expect(command.contains(#"--data-raw '{"name":"Ada"}'"#))
        // Headers sorted, so copying the same request twice produces the same text.
        #expect(
            command.range(of: "Authorization")!.lowerBound < command.range(of: "Content-Type")!.lowerBound
        )
    }

    @Test("A stopped server yields a path-only command rather than a wrong port")
    func curlWithoutPort() {
        let log = RequestLog(method: .get, path: "/health")

        #expect(RequestLogExport.curl(for: log, port: nil) == "curl -X GET '/health'")
    }

    @Test("Single quotes in a body cannot break out of the shell quoting")
    func escapesSingleQuotes() {
        let log = RequestLog(
            method: .post,
            path: "/notes",
            requestBody: #"{"text":"it's fine"}"#
        )

        let command = RequestLogExport.curl(for: log, port: 3000)

        #expect(command.contains(#"'{"text":"it'\''s fine"}'"#))
    }

    @Test("A body with no request payload omits the data flag")
    func omitsEmptyBody() {
        let log = RequestLog(method: .get, path: "/health", requestBody: "")

        #expect(RequestLogExport.curl(for: log, port: 3000).contains("--data-raw") == false)
    }

    @Test("Copying a response body formats it the same way the view shows it")
    func formatsBodyForCopying() {
        #expect(RequestLogExport.formattedBody(#"{"a":1}"#) == "{\n  \"a\": 1\n}")
        #expect(RequestLogExport.formattedBody("plain") == "plain")
    }
}
