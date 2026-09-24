import AppKit
import CommonCrypto
import Domain
import Foundation

/// Downloads a release, proves it is the file GitHub published, and hands it to macOS to install.
///
/// **Mimic never installs anything itself.** It fetches a package and asks LaunchServices to open it,
/// which lands in `Installer.app`; the user sees what they are installing, approves it with an admin
/// password, and macOS does the work. That is not a limitation being worked around, it is the design:
/// the installer replaces `/Applications/Mimic.app` **and** `/usr/local/bin/mimic` in one operation,
/// so the app and the command line tool can never end up a version apart — the drift
/// `Scripts/package_release.sh` refuses to ship, reproduced on a user's machine instead.
///
/// `nonisolated`: everything here is file and network work that must stay off the main actor. The
/// handoff at the end is the exception and says so.
nonisolated protocol UpdateInstalling: Sendable {
    func download(_ release: UpdateRelease, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func verify(_ fileURL: URL, against release: UpdateRelease) throws
    func stampQuarantine(on fileURL: URL, from release: UpdateRelease)
    @MainActor func handOff(_ fileURL: URL) async throws
}

nonisolated struct UpdateInstaller: UpdateInstalling {

    /// The team the installer must be signed by.
    ///
    /// Pinned rather than merely "signed by somebody": a package signed with *any* Developer ID
    /// passes a check for the presence of a signature, and the point of checking is to know it is
    /// **this** developer's. The value is the team in
    /// `Developer ID Installer: DEVXA LTD (KW6369JJL9)`, which is the identity
    /// `Scripts/package_release.sh` signs with.
    static let expectedTeamID = "KW6369JJL9"

    enum InstallError: Error, LocalizedError, Equatable {
        case downloadFailed(String)
        case wrongSize(expected: Int, actual: Int)
        case checksumMismatch(expected: String, actual: String)
        case notSignedByMimic(String)
        case handoffFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let detail):
                return "The download did not finish. \(detail)"
            case let .wrongSize(expected, actual):
                return "The download is \(actual) bytes; the release says \(expected). It was not installed."
            case .checksumMismatch:
                return """
                The downloaded file does not match the checksum GitHub published for it, so Mimic \
                will not install it. This is usually a corrupted or interrupted download — try \
                again. If it keeps happening, download the installer from the releases page \
                instead.
                """
            case .notSignedByMimic(let detail):
                return """
                The downloaded installer is not signed by Mimic's developer certificate, so it was \
                not installed. \(detail)
                """
            case .handoffFailed(let detail):
                return "Mimic could not open the installer. \(detail)"
            }
        }
    }

    private let session: URLSession

    /// `FileManager.default` is used directly rather than injected: it is not `Sendable`, so holding
    /// one would make this type unable to cross the actor boundary it exists to work on. Every call
    /// below is a plain path operation, which `FileManager` documents as safe from any thread.
    private var fileManager: FileManager { .default }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Where the download lands

    /// Inside the app's own container, which is both allowed under the sandbox and readable by
    /// `Installer.app` once LaunchServices hands the file over — measured, not assumed.
    ///
    /// Caches rather than Application Support: this is a large file with no value after the install,
    /// and Caches is the directory macOS is allowed to reclaim. It sits beside the project store's
    /// directory but never inside it — nothing in `Application Support/devxa.Mimic` should be
    /// anything but the store and its backups.
    func downloadDirectory() throws -> URL {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("Updates", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Download

    /// Fetches the release's installer, reporting progress as a fraction of the expected size.
    func download(
        _ release: UpdateRelease,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let directory = try downloadDirectory()
        let destination = directory.appendingPathComponent(release.asset.name)
        // A leftover from an interrupted attempt is not a head start: it may be a partial file, and
        // it would fail the checksum in a way that reads as "the release is corrupt".
        try? fileManager.removeItem(at: destination)

        var request = URLRequest(url: release.asset.downloadURL)
        request.timeoutInterval = 60

        let delegate = DownloadProgress(expectedBytes: release.asset.sizeInBytes, onProgress: onProgress)
        let temporaryURL: URL
        do {
            (temporaryURL, _) = try await session.download(for: request, delegate: delegate)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        return destination
    }

    // MARK: - Verification

    /// Refuses anything that is not byte-for-byte the published release.
    ///
    /// Two independent checks, because they fail for different reasons and only one of them can be
    /// defeated on purpose. The checksum catches a truncated or corrupted download; the signature
    /// catches a file that is intact and *not ours*.
    func verify(_ fileURL: URL, against release: UpdateRelease) throws {
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        if let size, size != release.asset.sizeInBytes {
            throw InstallError.wrongSize(expected: release.asset.sizeInBytes, actual: size)
        }

        let digest = try sha256(of: fileURL)
        guard digest == release.asset.sha256 else {
            throw InstallError.checksumMismatch(expected: release.asset.sha256, actual: digest)
        }

        try verifySignature(of: fileURL)
    }

    /// Streams the file rather than reading it whole.
    ///
    /// The installer is around 55 MB. `Data(contentsOf:)` would hold all of it resident to compute
    /// one 32-byte answer, on the machine of somebody who is mid-task.
    ///
    /// **CommonCrypto rather than CryptoKit, and that is not a style preference.** CryptoKit is a
    /// separate framework, so using it added `/System/Library/Frameworks/CryptoKit.framework` to
    /// `AppFeatures`' link list — one new dylib for the app to load at launch. Under `xcodebuild
    /// test` with a repo-local `-derivedDataPath` the app then hung inside dyld, in
    /// `loadDependents` → `makeDiskLoader`, before any of its own code ran: the whole `MimicTests`
    /// bundle failed with "the test runner hung before establishing connection", which reads as a
    /// broken test harness and is really a new link edge. `CommonCrypto` is part of libSystem, which
    /// every process has already loaded, so this computes the same digest and changes nothing about
    /// what the app links. Confirmed with `otool -L` on the built framework.
    func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { buffer in
                // A non-empty `Data` always has a base address; the guard is here because
                // `CC_SHA256_Update` with a null pointer is undefined rather than a no-op.
                guard let base = buffer.baseAddress else { return }
                _ = CC_SHA256_Update(&context, base, CC_LONG(buffer.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Asks `pkgutil` who signed the package.
    ///
    /// A flat `.pkg` cannot be verified with `SecStaticCode` the way an app bundle can — its
    /// signature is CMS in the archive header, and the in-process API that reads that
    /// (`SecAssessment`) is **not in the public SDK**: there is no `SecAssessment.h` in the macOS
    /// SDK and no entry for it in Security's module map. `pkgutil` is the supported way to ask, and
    /// spawning it works from inside the App Sandbox — verified against this project's own signed
    /// 0.10.0 package before this was written.
    ///
    /// One caveat is deliberate and must not be papered over: the sandbox suppresses `pkgutil`'s
    /// **notarisation** line, which needs a path out that the sandbox denies. So this proves *signed
    /// by our Developer ID*, not *notarised*. Notarisation is still enforced — by Gatekeeper, when
    /// Installer opens the quarantined file, which is why ``stampQuarantine(on:from:)`` exists.
    func verifySignature(of fileURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--check-signature", fileURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let output: String
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = String(decoding: data, as: UTF8.self)
        } catch {
            throw InstallError.notSignedByMimic("The signature could not be checked: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw InstallError.notSignedByMimic("It reports no valid signature at all.")
        }
        guard Self.isSignedByMimic(output) else {
            throw InstallError.notSignedByMimic("It is signed, but not by \(Self.expectedTeamID).")
        }
    }

    /// Whether `pkgutil --check-signature` output describes a package signed by this project.
    ///
    /// Separated from the process call so it can be tested against real `pkgutil` output — captured
    /// from the published 0.10.0 installer — without spawning anything.
    static func isSignedByMimic(_ pkgutilOutput: String) -> Bool {
        let lines = pkgutilOutput.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // The filename is printed before these fields and may itself contain the team ID. Check
        // the first certificate's identity as one line, rather than finding unrelated fragments
        // anywhere in the output. The real status and chain follow the filename, so use their last
        // occurrences if a filename happens to contain a newline and imitation field names.
        guard let status = lines.last(where: { $0.hasPrefix("Status:") }),
              status.hasPrefix("Status: signed by a developer certificate issued by Apple"),
              let chainIndex = lines.lastIndex(of: "Certificate Chain:"),
              lines.indices.contains(chainIndex + 1)
        else { return false }

        let signer = lines[chainIndex + 1]
        return signer.hasPrefix("1. Developer ID Installer: ")
            && signer.hasSuffix(" (\(expectedTeamID))")
    }

    // MARK: - Handoff

    /// Marks the file as downloaded from the internet, so Gatekeeper assesses it on open.
    ///
    /// `URLSession` does not set `com.apple.quarantine` — only LaunchServices and browsers do — so
    /// without this the package Installer opens is an unquarantined local file, and the notarisation
    /// check that this process cannot perform itself never happens either. Setting it puts the OS's
    /// own assessment back in the path, which is the check that cannot be talked out of.
    ///
    /// Best-effort by design: failing to *add* a restriction is not a reason to refuse an installer
    /// that has already matched its published checksum and its Developer ID.
    func stampQuarantine(on fileURL: URL, from release: UpdateRelease) {
        var url = fileURL
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Mimic",
            kLSQuarantineDataURLKey as String: release.asset.downloadURL.absoluteString,
            kLSQuarantineOriginURLKey as String: release.pageURL.absoluteString,
        ]
        try? url.setResourceValues(values)
    }

    /// Opens the package in `Installer.app`.
    ///
    /// `@MainActor` because `NSWorkspace` is, and because the caller quits immediately afterwards —
    /// the ordering between "Installer has the file" and "this process goes away" is the whole
    /// contract, and it is only observable on one actor.
    @MainActor
    func handOff(_ fileURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"),
                configuration: configuration
            )
        } catch {
            // Never a dead end: if the handoff fails, put the file in front of the user so the
            // update is still one double-click away rather than a message about a path.
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            throw InstallError.handoffFailed(error.localizedDescription)
        }
    }
}

/// Reports download progress as a fraction, clamped to `0...1`.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let expectedBytes: Int
    private let onProgress: @Sendable (Double) -> Void

    init(expectedBytes: Int, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The server's own Content-Length when it sent one, the release manifest's size otherwise:
        // a chunked response reports `NSURLSessionTransferSizeUnknown` (-1), which would otherwise
        // produce a negative fraction and a progress bar running backwards.
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(expectedBytes)
        guard total > 0 else { return }
        onProgress(min(1, max(0, Double(totalBytesWritten) / total)))
    }

    /// Required by the protocol; the `async` `download(for:delegate:)` call takes the file itself.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
