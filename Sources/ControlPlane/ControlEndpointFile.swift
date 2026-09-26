import Domain
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Mints the per-instance token.
///
/// A fresh token per process, never persisted beyond the discovery file: an instance that has exited
/// cannot have its credential replayed against the next one, and there is no long-lived secret on
/// disk to leak.
public enum ControlToken {
    /// 32 bytes of system randomness, hex-encoded. `SystemRandomNumberGenerator` is the platform CSPRNG
    /// (`arc4random_buf` on Darwin, `getrandom` on Linux).
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%016lx", generator.next() as UInt64) }
            .joined()
    }

    /// Compares in time independent of where the first difference falls.
    ///
    /// The control plane is loopback-only, so a remote timing attack is not the concern; a local
    /// process that can already time this precisely has easier routes. It is written this way because
    /// a token comparison that short-circuits is the kind of detail that gets copied into somewhere it
    /// does matter.
    public static func matches(_ presented: String?, expected: String) -> Bool {
        guard let presented, !expected.isEmpty else { return false }
        let lhs = Array(presented.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

/// Publishes and removes per-instance discovery records. Domain owns the shared path, reader and
/// destination/credential resolution rules in ControlEndpointDiscovery.
public enum ControlEndpointFile {

    /// Uses MIMIC_CONTROL_FILE when supplied, otherwise this app's Application Support directory.
    /// Newly created parent directories request 0700; existing permissions remain unchanged.
    public static func writeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = ControlEndpointDiscovery.overrideURL(in: environment) {
            try FileManager.default.createDirectory(
                at: override.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            return override
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("devxa.Mimic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        return directory.appendingPathComponent(ControlEndpointDiscovery.fileName)
    }

    /// Creates the record privately before atomic publication. Chmod after publishing would expose
    /// the token briefly. Publication and owner-checked removal share a stable sibling-file lock so
    /// another instance cannot replace a record between the ownership check and removal.
    public static func write(
        _ endpoint: ControlEndpoint,
        to url: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let target = try url ?? writeURL(environment: environment)
        let data = try ControlCoding.encoder(pretty: true).encode(endpoint)

        try withOwnershipLock(at: target) {
            try publish(data, to: target)
        }
    }

    private static func publish(_ data: Data, to target: URL) throws {
        // Create exclusively and keep the descriptor through the write. Reopening a predictable
        // pathname after creation would let a replacement redirect the credential write.
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")

        let manager = FileManager.default
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ControlEndpointFileError.couldNotWrite(path: temporary.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        do {
            try handle.write(contentsOf: data)
            // The sibling stays on the same filesystem, so publication atomically replaces the
            // directory entry and carries the private mode with it.
            guard rename(temporary.path, target.path) == 0 else {
                throw ControlEndpointFileError.couldNotWrite(path: target.path)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes an advertisement only while it still belongs to the caller.
    ///
    /// Two app instances can share the default discovery path. One may publish after the other,
    /// or fail to bind while the first remains active. A path alone does not identify the file that
    /// this instance wrote: unconditional cleanup would erase the other instance's advertisement.
    /// Refuse missing, damaged, or different records. Compare the whole decoded record, including
    /// the port, pid, and token, so a reused environment token cannot make a different process an
    /// owner of this file.
    /// The ownership check and removal share the writer's lock; if locking fails, leave the file
    /// in place rather than risking another instance's advertisement.
    public static func remove(expected: ControlEndpoint, at url: URL) {
        remove(expected: expected, at: url, afterOwnershipCheck: {})
    }

    // The hook lets a test hold the lock after reading the old record while a second writer tries
    // to replace it. Production always passes the empty closure above.
    static func remove(
        expected: ControlEndpoint,
        at url: URL,
        afterOwnershipCheck: () -> Void
    ) {
        try? withOwnershipLock(at: url) {
            guard let data = try? Data(contentsOf: url),
                  let current = try? ControlCoding.decode(ControlEndpoint.self, from: data),
                  current == expected
            else { return }
            afterOwnershipCheck()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A stable sibling lock serializes every writer with owner-checked cleanup across processes.
    /// Never unlink the lock file: replacing it would let two processes lock different inodes.
    private static func withOwnershipLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let path = url.path + ".lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ControlEndpointFileError.couldNotWrite(path: path)
        }
        defer { _ = close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw ControlEndpointFileError.couldNotWrite(path: path)
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Legacy fixture cleanup. Live server/app shutdown must use remove(expected:at:) so it cannot
    /// erase another instance's advertisement.
    @available(*, deprecated, message: "Use remove(expected:at:) for a live discovery file")
    public static func remove(
        at url: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let target = try? (url ?? writeURL(environment: environment)) else { return }
        try? FileManager.default.removeItem(at: target)
    }
}

/// Why a discovery file could not be written.
///
/// Typed rather than a bare `NSError` because the caller — `ControlServer` — has to decide whether an
/// instance that cannot advertise itself should still serve, and "the write failed" and "the rename
/// failed" are the same decision.
public enum ControlEndpointFileError: Error, LocalizedError, Equatable {
    case couldNotWrite(path: String)

    public var errorDescription: String? {
        switch self {
        case let .couldNotWrite(path):
            "Could not write the control discovery file at \(path)."
        }
    }
}
