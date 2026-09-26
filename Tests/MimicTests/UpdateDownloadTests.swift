import Domain
import Foundation
import Testing
@testable import AppFeatures

/// A URLSession transport fixture: no live feed, package, or installer is contacted.
private nonisolated final class UpdateResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: url.path == "/unavailable" ? 503 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "3"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Update download ownership")
struct UpdateDownloadTests {
    private func release(path: String = "/package", name: String = "Mimic.pkg", size: Int = 3) -> UpdateRelease {
        UpdateRelease(
            version: ReleaseVersion(major: 1, minor: 0, patch: 0), tag: "v1.0.0", title: "Mimic 1.0.0",
            notes: "", pageURL: URL(string: "https://example.invalid/release")!, publishedAt: .distantPast,
            asset: .init(
                name: name, downloadURL: URL(string: "https://example.invalid\(path)")!, sizeInBytes: size,
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        )
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("Separate attempts retain their own bytes and never use a feed name as a path")
    func downloadsHaveSeparateDestinations() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateDownloads-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = UpdateInstaller(session: session, downloadRoot: root)
        let release = release(name: "../../outside.pkg")

        let first = try await installer.download(release)
        let second = try await installer.download(release)

        #expect(first != second)
        #expect(first.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
        #expect(second.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
        #expect(first.lastPathComponent == "Mimic.pkg")
        #expect(try Data(contentsOf: first) == Data("abc".utf8))
        #expect(try Data(contentsOf: second) == Data("abc".utf8))
        installer.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: second) == Data("abc".utf8))
        installer.discard(second.deletingLastPathComponent().appendingPathComponent("unrelated.pkg"))
        #expect(try Data(contentsOf: second) == Data("abc".utf8))
    }

    @Test("An HTTP error never becomes a downloaded package")
    func refusesErrorResponse() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateDownloads-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = UpdateInstaller(session: session, downloadRoot: root)
        await #expect(throws: UpdateInstaller.InstallError.downloadFailed("The server returned HTTP 503.")) {
            _ = try await installer.download(release(path: "/unavailable"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("A download with the wrong byte count is refused before publication", arguments: [2, 4])
    func refusesWrongSizedDownload(expectedSize: Int) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateDownloads-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = UpdateInstaller(session: session, downloadRoot: root)
        await #expect(throws: UpdateInstaller.InstallError.wrongSize(expected: expectedSize, actual: 3)) {
            _ = try await installer.download(release(size: expectedSize))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Already-canceled checks and downloads preserve cancellation")
    func canceledNetworkWork() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let release = release()
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            await #expect(throws: CancellationError.self) {
                _ = try await UpdateInstaller(session: session).download(release)
            }
            await #expect(throws: CancellationError.self) {
                _ = try await UpdateFeedClient(session: session).latestRelease()
            }
        }
        task.cancel()
        gate.continuation.finish()
        await task.value
    }
}

@MainActor
@Suite("Update progress ownership")
struct UpdateProgressTests {
    private actor Downloads {
        private var callbacks: [@Sendable (Double) async -> Void] = []
        private var pending: [CheckedContinuation<URL, Never>] = []
        private(set) var discarded: [URL] = []
        var count: Int { callbacks.count }

        func download(_ callback: @escaping @Sendable (Double) async -> Void) async -> URL {
            callbacks.append(callback)
            return await withCheckedContinuation { pending.append($0) }
        }

        func report(_ fraction: Double, attempt: Int) async { await callbacks[attempt](fraction) }
        func finish() {
            for (index, continuation) in pending.enumerated() {
                continuation.resume(returning: URL(fileURLWithPath: "/fixture/\(index)/Mimic.pkg"))
            }
            pending.removeAll()
        }
        func discard(_ file: URL) { discarded.append(file) }
    }

    private nonisolated struct Installer: UpdateInstalling {
        let downloads: Downloads
        func download(_ release: UpdateRelease, onProgress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
            await downloads.download(onProgress)
        }
        func verify(_ fileURL: URL, against release: UpdateRelease) throws {}
        func stampQuarantine(on fileURL: URL, from release: UpdateRelease) throws {}
        func discard(_ fileURL: URL) { Task { await downloads.discard(fileURL) } }
        @MainActor func handOff(_ fileURL: URL) async throws { Issue.record("No installer handoff expected") }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await predicate(), "The expected update state did not arrive")
    }

    @Test("A canceled attempt cannot overwrite the progress of a retry of the same release")
    func staleProgressDoesNotReachRetry() async throws {
        let downloads = Downloads()
        let defaults = try #require(UserDefaults(suiteName: "UpdateProgressTests.\(UUID())"))
        let service = UpdateService(
            installedVersion: { ReleaseVersion(major: 0, minor: 10, patch: 0) },
            preferences: UpdatePreferences(defaults: defaults),
            fetchLatestRelease: { UpdateServiceTests.release("0.11.0") },
            installer: Installer(downloads: downloads), makeBackup: { _, _ in }, resolveStoreURL: { nil },
            flushPendingSave: {}, terminate: { Issue.record("No termination expected") }
        )
        service.checkForUpdates()
        try await waitUntil { if case .available = service.phase { true } else { false } }
        service.downloadAndPrepare()
        try await waitUntil { await downloads.count == 1 }
        service.dismiss()
        service.checkForUpdates()
        try await waitUntil { if case .available = service.phase { true } else { false } }
        service.downloadAndPrepare()
        try await waitUntil { await downloads.count == 2 }
        await downloads.report(0.4, attempt: 1)
        try await waitUntil {
            service.phase == .downloading(UpdateServiceTests.release("0.11.0"), fraction: 0.4)
        }
        await downloads.report(0.9, attempt: 0)
        await downloads.report(.nan, attempt: 1)
        // report awaits the actual MainActor acceptance/refusal, including stale and NaN values.
        #expect(service.phase == .downloading(UpdateServiceTests.release("0.11.0"), fraction: 0.4))
        await downloads.report(0.2, attempt: 1)
        #expect(service.phase == .downloading(UpdateServiceTests.release("0.11.0"), fraction: 0.4))
        await downloads.report(2, attempt: 1)
        try await waitUntil {
            service.phase == .downloading(UpdateServiceTests.release("0.11.0"), fraction: 1)
        }
        await downloads.finish()
        try await waitUntil { if case .readyToInstall = service.phase { true } else { false } }
        try await waitUntil { await downloads.discarded.count == 1 }
        #expect(await downloads.discarded == [URL(fileURLWithPath: "/fixture/0/Mimic.pkg")])
        #expect(service.phase == .readyToInstall(UpdateServiceTests.release("0.11.0"),
                                                installer: URL(fileURLWithPath: "/fixture/1/Mimic.pkg")))
    }
}
