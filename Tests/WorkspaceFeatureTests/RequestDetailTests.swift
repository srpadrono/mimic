import SwiftUI
import Testing
import Domain
import DesignSystem
@testable import AppFeatures

@Suite("Request detail formatting")
struct RequestDetailTests {

    // MARK: - Body rendering

    @Test("A body over the formatting limit is shown verbatim")
    func skipsFormattingForHugeBodies() {
        let huge = "{\"a\":\"" + String(repeating: "x", count: 20_480) + "\"}"
        let rendered = RequestBodyView.render(payload: huge)

        #expect(rendered.isFormatted == false)
        #expect(String(rendered.text.characters) == huge)
    }

    @Test("A small body stays verbatim when its formatted expansion exceeds the budget")
    func rejectedFormatterExpansionStaysVerbatim() {
        // This is only 701 bytes at input, so RequestBodyView passes it to JSONFormatter.
        // The formatter's indentation would expand the truncated nesting far past a normal body.
        let truncated = String(repeating: "[", count: 700) + "0"
        #expect(truncated.utf8.count == 701)

        let rendered = RequestBodyView.render(payload: truncated)
        #expect(rendered.isFormatted == false)
        #expect(String(rendered.text.characters) == truncated)
    }

    @Test("A normal body is formatted")
    func rendersFormattedBody() {
        let rendered = RequestBodyView.render(payload: #"{"id":1,"id2":2}"#)

        #expect(rendered.isFormatted)
        #expect(String(rendered.text.characters).contains("\n"))
    }

    @Test("A body with carriage-return line endings keeps its layout without a refusal")
    func carriageReturnLayoutIsPreservedWithoutARefusal() {
        let body = "{\r  \"ok\": true,\r  \"message\": \"ready\"\r}"

        let rendered = RequestBodyView.render(payload: body)

        #expect(rendered.isFormatted)
        #expect(String(rendered.text.characters) == body)
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

        #expect(command.hasPrefix("curl --globoff --path-as-is -X POST 'http://localhost:8080/api/users?dry=true'"))
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

        let expected = [
            "curl --globoff --path-as-is -X GET '/health'",
            "  -H 'Accept:'",
            "  -H 'User-Agent:'",
        ].joined(separator: " \\\n")
        #expect(RequestLogExport.curl(for: log, port: nil) == expected)
    }

    @Test("A HEAD command uses header-only handling and preserves its literal target")
    func curlUsesHeadModeAndPreservesTheRequestTarget() {
        let log = RequestLog(method: .head, path: "/a/../b?item[0]=one&item[1]=two")

        let expected = [
            "curl --globoff --path-as-is --head 'http://localhost:8080/a/../b?item[0]=one&item[1]=two'",
            "  -H 'Accept:'",
            "  -H 'User-Agent:'",
        ].joined(separator: " \\\n")
        #expect(RequestLogExport.curl(for: log, port: 8080) == expected)
    }

    @Test("A copied command keeps end-to-end headers and lets curl frame the captured body")
    func curlDoesNotReuseCapturedFramingHeaders() {
        let log = RequestLog(
            method: .post,
            path: "/framing",
            requestHeaders: [
                "Authorization": "Bearer fixture",
                "Content-Type": "text/plain",
                "X-Keep": "kept",
                "Content-Length": "999",
                "Transfer-Encoding": "chunked",
                "TE": "trailers",
                "Connection": "keep-alive, X-Hop",
                "x-hop": "connection only",
                "Keep-Alive": "timeout=5",
                "Proxy-Connection": "keep-alive",
                "Trailer": "X-Checksum",
                "Upgrade": "websocket",
            ],
            requestBody: "literal body"
        )

        let expected = [
            "curl --globoff --path-as-is -X POST 'http://localhost:8080/framing'",
            "  -H 'Authorization: Bearer fixture'",
            "  -H 'Content-Type: text/plain'",
            "  -H 'X-Keep: kept'",
            "  -H 'Accept:'",
            "  -H 'User-Agent:'",
            "  --data-raw 'literal body'",
        ].joined(separator: " \\\n")
        #expect(RequestLogExport.curl(for: log, port: 8080) == expected)
    }

    @Test("Empty captured headers stay present and absent curl defaults stay absent")
    func curlPreservesEmptyAndAbsentHeaderValues() {
        let log = RequestLog(
            method: .post,
            path: "/headers",
            requestHeaders: ["aCcEpT": "", "X-Empty": ""],
            requestBody: "unchanged"
        )
        let expected = [
            "curl --globoff --path-as-is -X POST 'http://localhost:8080/headers'",
            "  -H 'X-Empty;'",
            "  -H 'aCcEpT;'",
            "  -H 'User-Agent:'",
            "  -H 'Content-Type:'",
            "  --data-raw 'unchanged'",
        ].joined(separator: " \\\n")

        #expect(RequestLogExport.curl(for: log, port: 8080) == expected)
    }

    @Test("Incomplete or shell-incompatible bodies cannot become a misleading runnable command")
    func unavailableCurlRequestsReturnAnExplanation() {
        let truncated = RequestLog(
            method: .post, path: "/truncated", requestBody: "prefix", requestBodyTruncated: true
        )
        let nullByte = RequestLog(method: .post, path: "/binary", requestBody: "a\0b")
        let headBody = RequestLog(method: .head, path: "/head", requestBody: "body")

        #expect(RequestLogExport.curl(for: truncated, port: 8080)
            == "# The request body was truncated; a complete cURL command is unavailable.")
        #expect(RequestLogExport.curl(for: nullByte, port: 8080)
            == "# The request body contains a null byte and cannot be copied as a shell argument.")
        #expect(RequestLogExport.curl(for: headBody, port: 8080)
            == "# A HEAD request with a body cannot be reproduced with cURL's header-only mode.")
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

    // MARK: - Request, Response and Timing tabs

    @Test("The tabs are Request, Response and Timing")
    func tabsFollowTheDesign() {
        #expect(RequestDetailTab.allCases.map(\.rawValue) == ["Request", "Response", "Timing"])
    }

    @Test("The request URL prefers the port the request arrived on")
    func requestURLUsesTheListenerPort() {
        let logged = RequestLog(method: .get, path: "/recommendations?limit=4", listenerPort: 18086)
        let unlogged = RequestLog(method: .get, path: "/recommendations?limit=4")

        #expect(RequestDetailView.requestURL(for: logged, port: 8080)
                == "http://localhost:18086/recommendations?limit=4")
        #expect(RequestDetailView.requestURL(for: unlogged, port: 8080)
                == "http://localhost:8080/recommendations?limit=4")
        #expect(RequestDetailView.requestURL(for: unlogged, port: nil) == "/recommendations?limit=4")
    }

    @Test("The port row names the listener and its number")
    func portSummaryNamesTheListener() {
        let named = RequestLog(method: .get, path: "/", backendName: "Storefront", listenerPort: 18086)
        let bare = RequestLog(method: .get, path: "/", listenerPort: 18086)
        let unknown = RequestLog(method: .get, path: "/")

        #expect(RequestDetailView.portSummary(for: named) == "Storefront \u{00B7} 18086")
        #expect(RequestDetailView.portSummary(for: bare) == "18086")
        #expect(RequestDetailView.portSummary(for: unknown) == nil)
    }

    @Test("Query items keep their order, duplicates, bracketed names and decoding")
    func queryItemsAreSplitInOrder() {
        let items = RequestDetailView.queryItems(in: "/a?item[0]=one&item[1]=two&q=caf%C3%A9&flag&item[0]=again#top")

        #expect(items.map(\.name) == ["item[0]", "item[1]", "q", "flag", "item[0]"])
        #expect(items.map(\.value) == ["one", "two", "caf\u{00E9}", nil, "again"])
        #expect(RequestDetailView.queryItems(in: "/products/42").isEmpty)
        #expect(RequestDetailView.queryItems(in: "/products?").isEmpty)
    }
}
