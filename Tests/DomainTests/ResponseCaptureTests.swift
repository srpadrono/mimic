import Foundation
import Testing
@testable import Domain

@Suite("Safe response capture")
struct ResponseCaptureTests {
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
