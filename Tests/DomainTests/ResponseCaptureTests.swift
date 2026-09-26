import Foundation
import Testing
@testable import Domain

@Suite("Safe response capture")
struct ResponseCaptureTests {
    @Test("Media type parameters allow whitespace before their semicolon", arguments: [
        "application/json ; charset=utf-8",
        "Application/Problem+JSON\t; charset=utf-8",
        " application/xml ; charset=utf-8 ",
        "text/plain ; charset=utf-8",
    ])
    func acceptsTextMediaTypeWhitespace(contentType: String) throws {
        let log = RequestLog(method: .get, path: "/text", responseStatusCode: 200,
            responseHeaders: ["Content-Type": contentType], responseBody: "42", outcome: .passthrough)
        #expect(ResponseCapture.isTextMediaType(contentType))
        #expect(try ResponseCapture.body(log) == "42")
    }

    @Test("Media type whitespace does not make binary data capturable", arguments: [
        "application/octet-stream ; name=response",
        "image/png\t; name=photo",
    ])
    func rejectsBinaryMediaTypeWhitespace(contentType: String) {
        let log = RequestLog(method: .get, path: "/binary", responseStatusCode: 200,
            responseHeaders: ["Content-Type": contentType], responseBody: "bytes", outcome: .passthrough)
        #expect(!ResponseCapture.isTextMediaType(contentType))
        #expect(throws: ControlError.self) { try ResponseCapture.body(log) }
    }

    @Test("A missing HTTP response cannot become a successful mock")
    func refusesMissingResponses() {
        let logs = [
            RequestLog(method: .get, path: "/offline", failureLabel: "connection-drop", outcome: .journey),
            RequestLog(method: .get, path: "/timeout", failureLabel: "timeout(30000ms)", outcome: .journey),
            RequestLog(method: .get, path: "/unknown", outcome: .endpoint),
            RequestLog(method: .get, path: "/failed", responseStatusCode: 200,
                       failureLabel: "connection-drop", outcome: .journey),
        ]
        for log in logs {
            #expect(throws: ControlError.self) { try ResponseCapture.validate(log) }
            #expect(throws: ControlError.self) { try ResponseCapture.body(log) }
        }
    }

    @Test("Complete capture storage is independent of the 64 KiB preview and never serialized")
    func completeBodyAndPreviewAreSeparate() throws {
        let body = "{\"data\":\"" + String(repeating: "a", count: 70000) + "\"}"
        let captured = CapturedResponseBody(byteCount: body.utf8.count) { body }
        let log = RequestLog(method: .get, path: "/large", responseStatusCode: 200,
            responseHeaders: ["Content-Type": "application/json"], responseBody: "{\"data\":\"a",
            responseBodyTruncated: true, capturedResponseBody: captured, outcome: .passthrough)
        #expect(try ResponseCapture.body(log) == body)
        #expect(try JourneyStepSpec.capturing(log).body == body)
        let encoded = try JSONEncoder().encode(log)
        #expect(encoded.count < 1000)
        let decoded = try JSONDecoder().decode(RequestLog.self, from: encoded)
        #expect(decoded.capturedResponseBody == nil)
        #expect(log.redactingCredentials().capturedResponseBody == nil)
        #expect(throws: ControlError.self) { try ResponseCapture.body(decoded) }
    }

    @Test("The capture boundary is exactly 5 MiB and storage errors cannot save a prefix")
    func completeBodyBoundary() throws {
        #expect(ResponseCapture.maxBodyBytes == 5_242_880)
        for size in [5_242_880, 5_242_881] {
            let log = RequestLog(method: .get, path: "/large", responseStatusCode: 200,
                responseBody: "preview", responseBodyTruncated: true,
                capturedResponseBody: CapturedResponseBody(byteCount: size) { "complete" }, outcome: .passthrough)
            if size == 5_242_880 { try ResponseCapture.validate(log) }
            else { #expect(throws: ControlError.self) { try ResponseCapture.validate(log) } }
        }
        let unavailable = RequestLog(method: .get, path: "/lost", responseStatusCode: 200,
            responseBody: "preview", responseBodyTruncated: true,
            capturedResponseBody: CapturedResponseBody(byteCount: 70000) { throw CocoaError(.fileReadNoSuchFile) },
            outcome: .passthrough)
        #expect(throws: ControlError.self) { try ResponseCapture.body(unavailable) }
    }

    @Test("Cache validators, partial bodies and empty JSON cannot become complete mocks")
    func refusesIncompleteRepresentations() {
        let responses = [
            RequestLog(method: .get, path: "/cached", responseStatusCode: 304, responseBody: "", outcome: .passthrough),
            RequestLog(method: .get, path: "/range", responseStatusCode: 206,
                       responseHeaders: ["Content-Type": "application/json"], responseBody: "1", outcome: .passthrough),
            RequestLog(method: .get, path: "/range", responseStatusCode: 200,
                       responseHeaders: ["Content-Range": "bytes 5-5/20"], responseBody: "1", outcome: .passthrough),
            RequestLog(method: .get, path: "/empty", responseStatusCode: 200,
                       responseHeaders: ["Content-Type": "application/json"], responseBody: "", outcome: .passthrough),
            RequestLog(method: .get, path: "/missing", responseStatusCode: 200,
                       responseHeaders: ["Content-Type": "application/problem+json; charset=utf-8"], outcome: .passthrough),
        ]
        for log in responses {
            #expect(throws: ControlError.self) { try ResponseCapture.validate(log) }
            #expect(throws: ControlError.self) { try JourneyStepSpec.capturing(log) }
        }
    }

    @Test("JSON scalars and intentionally bodyless responses remain capturable")
    func preservesCompleteRepresentations() throws {
        for body in ["true", "false", "null", "1", "[]", "{}", #""hello""#, #"{"name":"日本語 🧪","enabled":true}"#] {
            let log = RequestLog(method: .get, path: "/json", responseStatusCode: 200,
                responseHeaders: ["Content-Type": "application/json"], responseBody: body, outcome: .passthrough)
            try ResponseCapture.validate(log)
            #expect(try JourneyStepSpec.capturing(log).body == body)
        }
        for (method, status) in [(HTTPMethod.head, 200), (.get, 204), (.get, 205)] {
            try ResponseCapture.validate(RequestLog(method: method, path: "/empty", responseStatusCode: status,
                responseHeaders: ["Content-Type": "application/json"], responseBody: "", outcome: .passthrough))
        }
    }

    @Test("Compressed JSON explains encoding instead of calling the payload binary")
    func compressedJSONDiagnostic() {
        let log = RequestLog(method: .get, path: "/json", responseBodyIsBinary: true, responseStatusCode: 200,
            responseHeaders: ["Content-Type": "application/json", "Content-Encoding": "gzip"], outcome: .passthrough)
        do {
            try ResponseCapture.validate(log)
            Issue.record("Compressed wire bytes must not be saved as text")
        } catch {
            #expect(error.localizedDescription.contains("compressed"))
            #expect(error.localizedDescription.contains("Accept-Encoding: identity"))
        }
    }

    @Test func trafficSearchFindsTheServingBackend() {
        let log = RequestLog(method: .get, path: "/profile", backendName: "Accounts", listenerPort: 18081,
            upstreamURL: "https://accounts.example.com/profile", outcome: .passthrough)
        for query in ["accounts", "18081", "example.com"] { #expect(RequestLogFilter(text: query).matches(log)) }
    }

    @Test func refusesUnsupportedResponses() {
        let binary = RequestLog(method: .get, path: "/image", responseBodyIsBinary: true, responseStatusCode: 200, outcome: .passthrough)
        let partial = RequestLog(method: .get, path: "/large", responseStatusCode: 200, responseBody: "partial", responseBodyTruncated: true, outcome: .passthrough)
        let failed = RequestLog(method: .get, path: "/offline", responseStatusCode: 502, outcome: .proxyFailure)
        let compressed = RequestLog(method: .get, path: "/gzip", responseStatusCode: 200, responseHeaders: ["Content-Encoding": "gzip"], outcome: .passthrough)
        let partialRequest = RequestLog(method: .post, path: "/graphql", requestBody: "{partial", requestBodyTruncated: true,
            responseStatusCode: 200, responseBody: "{}", outcome: .passthrough)
        for log in [binary, partial, failed, compressed, partialRequest] {
            #expect(throws: ControlError.self) { try ResponseCapture.validate(log) }
            #expect(throws: ControlError.self) { try JourneyStepSpec.capturing(log) }
        }
    }

    @Test func capturesSafeHeadersAndGraphQLOperation() throws {
        let log = RequestLog(method: .post, path: "/graphql", requestBody: #"{"query":"query Account { me { id } }","operationName":"Account"}"#,
            responseStatusCode: 200, responseHeaders: ["Content-Type": "application/problem+json", "Set-Cookie": "private", "X-API-Key": "secret", "Connection": "x-private", "x-private": "transport", "ETag": "v1"], responseBody: "{}", outcome: .passthrough)
        let spec = try JourneyStepSpec.capturing(log)
        #expect(spec.graphqlOperation == "Account")
        #expect(spec.headers == ["Content-Type": "application/problem+json", "ETag": "v1"])
    }

    @Test("Saved mocks do not replay upstream telemetry, rate limits, or reporting destinations")
    func dropsTransientUpstreamHeaders() throws {
        let captured: [String: String] = [
            "Content-Type": "application/json", "Cache-Control": "no-store", "ETag": "v1",
            "CF-Ray": "one-request", "CF-Cache-Status": "HIT", "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "123456", "NEL": #"{"report_to":"upstream"}"#,
            "Report-To": #"{"url":"https://upstream.example/reports"}"#,
            "Strict-Transport-Security": "max-age=31536000", "Alt-Svc": "h3=\":443\"",
            "Server-Timing": "origin;dur=42", "X-Request-ID": "one-request",
            "Proxy-Connection": "keep-alive",
        ]
        let expected = ["Content-Type": "application/json", "Cache-Control": "no-store", "ETag": "v1"]
        #expect(ResponseCapture.headers(captured) == expected)

        let log = RequestLog(method: .get, path: "/profile", responseStatusCode: 200,
            responseHeaders: captured, responseBody: "{}", outcome: .passthrough)
        let step = try JourneyStepSpec.capturing(log)
        #expect(step.headers == ["Cache-Control": "no-store", "ETag": "v1"])
        #expect(step.contentType == .json)
    }

    @Test func failedConfigurationDoesNotPartiallyMutateProject() throws {
        var project = MockProject(name: "Atomic", serverConfiguration: .init(port: 8080, globalDelayMs: 0))
        let original = project
        #expect(throws: ControlError.self) {
            try ProjectCommandExecutor.apply(.serverConfigure(port: 9090, globalDelayMs: -1), to: &project)
        }
        #expect(project == original)
        #expect(throws: ControlError.self) {
            try ProjectCommandExecutor.apply(.serverConfigure(port: nil, globalDelayMs: nil,
                configuration: .init(port: 9090, globalDelayMs: -1)), to: &project)
        }
        #expect(project == original)
    }

    @Test func disabledBackendKeepsItsURL() throws {
        var project = MockProject(name: "Pause", serverConfiguration: .init(port: 8080, globalDelayMs: 0, upstreamURL: "https://api.example.com"))
        _ = try ProjectCommandExecutor.apply(.serverConfigure(port: nil, globalDelayMs: nil, upstreamURL: ""), to: &project)
        #expect(project.serverConfiguration.upstreamURL == "https://api.example.com")
        #expect(project.serverConfiguration.backend(id: nil)?.effectiveUpstream == nil)
    }
}
