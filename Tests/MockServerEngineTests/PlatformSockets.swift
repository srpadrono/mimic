#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A thin platform shim for the BSD socket calls the raw-HTTP tests need.
///
/// Two things differ between Darwin and Glibc and both are easy to trip over: the calls have to be
/// module-qualified to avoid colliding with local names, and a few constants have different types
/// (`SOCK_STREAM` is `Int32` on Darwin and `__socket_type` on Linux; `timeval.tv_usec` is `Int32`
/// against `__suseconds_t`). Wrapping them here keeps the tests readable and lets them run on the
/// Linux CI rather than being macOS-only.
enum PlatformSocket {

    /// `SOCK_STREAM` as the `Int32` that `socket(_:_:_:)` expects on both platforms.
    static var streamType: Int32 {
        #if canImport(Darwin)
        SOCK_STREAM
        #else
        Int32(SOCK_STREAM.rawValue)
        #endif
    }

    static func make() -> Int32 {
        #if canImport(Darwin)
        Darwin.socket(AF_INET, streamType, 0)
        #else
        Glibc.socket(AF_INET, streamType, 0)
        #endif
    }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }

    static func bind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.bind(descriptor, address, length)
        #else
        Glibc.bind(descriptor, address, length)
        #endif
    }

    static func connect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(descriptor, address, length)
        #else
        Glibc.connect(descriptor, address, length)
        #endif
    }

    static func send(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ length: Int) -> Int {
        #if canImport(Darwin)
        Darwin.send(descriptor, buffer, length, 0)
        #else
        Glibc.send(descriptor, buffer, length, 0)
        #endif
    }

    static func receive(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int) -> Int {
        #if canImport(Darwin)
        Darwin.recv(descriptor, buffer, length, 0)
        #else
        Glibc.recv(descriptor, buffer, length, 0)
        #endif
    }

    static func localAddress(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        #if canImport(Darwin)
        Darwin.getsockname(descriptor, address, length)
        #else
        Glibc.getsockname(descriptor, address, length)
        #endif
    }

    /// A receive timeout, built with whatever integer widths the platform's `timeval` uses.
    static func receiveTimeout(seconds: Double) -> timeval {
        let whole = Int(seconds)
        let fractionalMicroseconds = (seconds - Double(whole)) * 1_000_000
        #if canImport(Darwin)
        return timeval(tv_sec: whole, tv_usec: Int32(fractionalMicroseconds))
        #else
        return timeval(tv_sec: whole, tv_usec: Int(fractionalMicroseconds))
        #endif
    }

    static func setReceiveTimeout(_ descriptor: Int32, seconds: Double) {
        var timeout = receiveTimeout(seconds: seconds)
        #if canImport(Darwin)
        _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #else
        _ = Glibc.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    /// A loopback `sockaddr_in` for the given port, `0` meaning "let the OS choose".
    static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port == 0 ? 0 : port.bigEndian
        return address
    }

    /// Asks the OS for a free loopback port by binding one and closing it immediately.
    ///
    /// Fixed port numbers make a suite that fails only on someone else's machine.
    static func freePort() -> Int? {
        let descriptor = make()
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                localAddress(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}
