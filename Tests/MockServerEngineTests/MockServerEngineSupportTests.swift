import Foundation
import Testing
import Domain
@testable import MockServerEngine

@Suite("MockServerEngine Support")
struct MockServerEngineSupportTests {
    @Test("The wire client detects truncated non-UTF-8 bodies")
    func wireLengthCountsBytes() {
        let short = Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".utf8) + Data([0xFF])
        let complete = Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n".utf8) + Data([0xFF])
        #expect(!RawHTTPClient.isComplete(short))
        #expect(RawHTTPClient.isComplete(complete))
    }

    @Test("Bodyless responses do not require the representation's advertised length")
    func wireBodylessResponses() {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: 128\r\n\r\n".utf8)
        #expect(RawHTTPClient.isComplete(head, method: "HEAD"))
        #expect(!RawHTTPClient.isComplete(head, method: "GET"))
        #expect(RawHTTPClient.isComplete(Data("HTTP/1.1 304 Not Modified\r\nContent-Length: 128\r\n\r\n".utf8)))
    }

    @Test("A terminating chunk cannot conceal a short earlier chunk")
    func wireChunksHonorTheirLengthsAndTrailers() {
        let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(!RawHTTPClient.isComplete(Data((header + "A\r\nabc\r\n0\r\n\r\n").utf8)))
        #expect(RawHTTPClient.isComplete(Data((header + "3\r\nabc\r\n0\r\nChecksum: ok\r\n\r\n").utf8)))
        #expect(!RawHTTPClient.isComplete(Data((header + "3\r\nabc\r\n0\r\nChecksum: ok\r\n").utf8)))
        #expect(!RawHTTPClient.isComplete(Data((header + "\r\n").utf8)))
        #expect(!RawHTTPClient.isComplete(Data((header + "FFFFFFFFFFFFFFFFFFFFFFFF\r\n").utf8)))
    }

    @Test("Malformed framing and an interim response alone are incomplete", arguments: [
        "HTTP/1.1 200 OK\r\nContent-Length: invalid\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc",
        "HTTP/1.1 100 Continue\r\n\r\n",
    ])
    func wireMalformedFraming(raw: String) {
        #expect(!RawHTTPClient.isComplete(Data(raw.utf8)))
    }

    @Test("An informational response can precede a complete final response")
    func wireInformationalResponse() {
        let raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        #expect(RawHTTPClient.isComplete(Data(raw.utf8)))
    }

    @Test("MockServerError descriptions are stable")
    func mockServerErrorDescriptions() {
        #expect(MockServerError.portInUse(port: 8080).errorDescription == "Port 8080 is already in use.")
        #expect(MockServerError.alreadyRunning.errorDescription == "Server is already running.")
        #expect(MockServerError.notRunning.errorDescription == "Server is not running.")
        #expect(
            MockServerError.invalidState(.starting).errorDescription
                == "Cannot perform operation in state: starting."
        )
    }
}
