import Domain
import Foundation

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
        guard let presented else { return false }
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

/// The write half of the discovery-file contract: how a running instance advertises itself.
///
/// The *read* half — the search paths, the `MIMIC_CONTROL_FILE` override, pid liveness, and the
/// resolution rules a client applies — is `ControlEndpointDiscovery` in `Domain`, and this enum
/// delegates every path decision to it. It used to carry a reader of its own, a twin of the one the
/// CLI carries, and the two drifted (see `ControlEndpointDiscovery`'s documentation); what stays
/// here is only what a *writer* needs, because writing is the one thing a Vapor-linking host does
/// that a client never should.
public enum ControlEndpointFile {

    /// Where *this* process should write its discovery file: wherever `MIMIC_CONTROL_FILE` names, or
    /// alongside its own Application Support, whichever container that resolves to.
    ///
    /// The override is resolved by `ControlEndpointDiscovery.overrideURL(in:)` — the same function
    /// every reader resolves it with — so the file a run writes and the file a run reads cannot
    /// drift apart. Computing the default path here while a reader honoured the override is how a
    /// run would delete the developer's advertisement and leave its own behind — the exact pair of
    /// mistakes `UITestSupport.databaseURL` exists to prevent for the store.
    ///
    /// Both branches create the parent directory, and both ask for `0700`: the file inside carries
    /// this instance's token, so a directory somebody else can list is not a place to put it. The
    /// override gets the same treatment as the computed path because it holds the same secret — an
    /// isolated run is not a less sensitive one.
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

    /// Writes the discovery file `0600`, and never at any wider mode, even briefly.
    ///
    /// The file carries the instance's token, so its permissions are the access control. A plain
    /// `write(to:options:.atomic)` lands at `0644` under the default umask, which publishes the token
    /// to every account on the machine — on a shared box or a CI host, that is the whole
    /// authentication story undone.
    ///
    /// Chmod-after-write does not fix it, which is what this used to do: `.atomic` writes a temporary
    /// file and renames it into place, so between that rename and the `setAttributes` call the token
    /// is sitting at the final path, readable by anyone who is looking. A loop watching the path wins
    /// that race trivially. Worse, if `setAttributes` threw, the throw left the world-readable file
    /// behind — and `ControlServer` called this through `try?`, so nothing was reported either. That
    /// half is fixed at the call site now: `ControlServer.start` catches what this throws and logs
    /// it. Keep it that way. A hardened write whose caller discards the error is not hardened; it
    /// only moves the silence one frame up.
    ///
    /// So the mode is applied to the temporary file *before* it becomes visible under the real name,
    /// and `rename(2)` — which replaces atomically and carries the source's mode with it — publishes
    /// it. A reader therefore sees either the old file or a complete `0600` one, and never a partial
    /// or a wide one.
    public static func write(
        _ endpoint: ControlEndpoint,
        to url: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let target = try url ?? writeURL(environment: environment)
        let data = try ControlCoding.encoder(pretty: true).encode(endpoint)

        // Same directory, so the rename stays within one filesystem and is therefore atomic.
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")

        let manager = FileManager.default
        try? manager.removeItem(at: temporary)
        guard manager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw ControlEndpointFileError.couldNotWrite(path: temporary.path)
        }

        do {
            try data.write(to: temporary)
            guard rename(temporary.path, target.path) == 0 else {
                throw ControlEndpointFileError.couldNotWrite(path: target.path)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the file so a stale endpoint never outlives the process that advertised it.
    ///
    /// Takes the same environment as `writeURL`, so a process that advertised itself at
    /// `MIMIC_CONTROL_FILE` removes *that* file on the way out. Computing the default path here
    /// while the write went to an override is how a run would delete the developer's advertisement
    /// and leave its own behind — the exact pair of mistakes `UITestSupport.databaseURL` exists to
    /// prevent for the store, and the reason both paths come from one function here too.
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
