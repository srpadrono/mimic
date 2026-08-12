import SwiftUI
import Testing
import Domain
import DesignSystem
@testable import AppFeatures

@Suite("Request detail formatting")
struct RequestDetailTests {

    // MARK: - JSON layout

    @Test("Minified JSON is re-indented")
    func prettyPrintsMinifiedJSON() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"id":1,"name":"Ada"}"#))

        #expect(formatted == """
        {
          "id": 1,
          "name": "Ada"
        }
        """)
    }

    @Test("Key order survives formatting")
    func preservesKeyOrder() throws {
        // The reason this is a character scanner and not JSONSerialization: a round trip through a
        // dictionary reorders keys, so the body shown would not be the body served.
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"zebra":1,"apple":2,"mango":3}"#))
        let keys = formatted
            .split(separator: "\n")
            .compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }

        #expect(keys == ["zebra", "apple", "mango"])
    }

    @Test("Braces and brackets inside strings do not change indentation")
    func ignoresStructureInsideStrings() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"pattern":"{a,b}[c]","n":1}"#))

        #expect(formatted == """
        {
          "pattern": "{a,b}[c]",
          "n": 1
        }
        """)
    }

    @Test("An escaped quote does not end the string")
    func handlesEscapedQuotes() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"say":"he said \"hi\"","n":2}"#))

        #expect(formatted.contains(#""say": "he said \"hi\"""#))
        #expect(formatted.contains(#""n": 2"#))
    }

    @Test("Empty containers stay on one line")
    func keepsEmptyContainersInline() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"items":[],"meta":{}}"#))

        #expect(formatted == """
        {
          "items": [],
          "meta": {}
        }
        """)
    }

    @Test("Nested structures indent by depth")
    func indentsNestedStructures() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"a":{"b":[1,2]}}"#))

        #expect(formatted == """
        {
          "a": {
            "b": [
              1,
              2
            ]
          }
        }
        """)
    }

    @Test("Non-JSON and already-formatted bodies are left alone")
    func skipsWhatItShouldNotTouch() {
        #expect(JSONFormatter.prettyPrinted("plain text response") == nil)
        #expect(JSONFormatter.prettyPrinted("") == nil)
        #expect(JSONFormatter.prettyPrinted("<html><body>hi</body></html>") == nil)
        // Already laid out across lines — whoever produced it chose a layout.
        #expect(JSONFormatter.prettyPrinted("{\n  \"a\": 1\n}") == nil)
    }

    @Test("A truncated body still formats")
    func formatsTruncatedJSON() throws {
        // The log caps bodies at 64 KB, so a cut-off payload is a normal input here. A parser would
        // refuse it outright; the scanner has to degrade instead.
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"a":1,"b":"unterminat"#))

        #expect(formatted.hasPrefix("{\n  \"a\": 1,"))
    }

    // MARK: - Tokenising

    @Test("Keys, strings, numbers, and literals are told apart")
    func classifiesTokens() {
        let tokens = JSONFormatter.tokenize(#"{"name":"Ada","age":36,"active":true,"note":null}"#)

        func kind(of text: String) -> JSONFormatter.TokenKind? {
            tokens.first { $0.text == text }?.kind
        }

        #expect(kind(of: #""name""#) == .key)
        #expect(kind(of: #""Ada""#) == .string)
        #expect(kind(of: "36") == .number)
        #expect(kind(of: "true") == .literal)
        #expect(kind(of: "null") == .literal)
        #expect(kind(of: "{") == .punctuation)
    }

    @Test("A string is a key only when a colon follows it")
    func distinguishesKeysFromValues() {
        let tokens = JSONFormatter.tokenize(#"["alpha","beta"]"#)

        #expect(tokens.contains { $0.text == #""alpha""# && $0.kind == .string })
        #expect(tokens.contains(where: { $0.kind == .key }) == false)
    }

    @Test("Non-JSON tokenises as a single plain run")
    func tokenizesNonJSONAsPlain() {
        let tokens = JSONFormatter.tokenize("not json at all")

        #expect(tokens == [JSONFormatter.Token(text: "not json at all", kind: .plain)])
    }

    @Test("Tokens reassemble into the original text")
    func tokenizingIsLossless() {
        let source = #"{"a":[1,true,null],"b":"x y"}"#
        let rejoined = JSONFormatter.tokenize(source).map(\.text).joined()

        #expect(rejoined == source)
    }

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
