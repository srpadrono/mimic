import Darwin
import Foundation
import Testing
@testable import FeatureSupport

@Suite("Port probe")
struct PortProbeTests {

    /// A listening loopback socket on a port the kernel picks, returned with that port.
    private func listen() throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(descriptor, raw, length) == 0
                    && Darwin.listen(descriptor, 1) == 0
                    && getsockname(descriptor, raw, &length) == 0
            }
        }
        try #require(bound)
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    @Test("A port something is listening on is not available, and is again once it closes")
    func listeningPortIsTaken() throws {
        let listener = try listen()
        #expect(PortProbe.isAvailable(listener.port) == false)
        close(listener.descriptor)
        #expect(PortProbe.isAvailable(listener.port))
    }

    @Test("A port outside 1…65535 is never available")
    func outOfRangePortsAreRefused() {
        #expect(PortProbe.isAvailable(0) == false)
        #expect(PortProbe.isAvailable(65_536) == false)
    }
}
