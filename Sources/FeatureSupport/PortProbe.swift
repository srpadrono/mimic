import Darwin

/// Whether a port is free to serve on, asked the only way that is not a guess: by binding it.
///
/// The new-project sheet and server settings show the answer beside the port field. It is advice,
/// not a reservation — something else can take the port between the check and a server start, and
/// the start reports that conflict as it always has.
public enum PortProbe {
    /// `true` when a TCP socket can bind `port` on the loopback interface, where the mock server
    /// listens. A port Mimic itself is serving on reads as taken.
    public nonisolated static func isAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
