import Domain
import Foundation
import Testing
@testable import AppFeatures

private nonisolated final class UpdateCancellationObservation: @unchecked Sendable {
    let started = AsyncStream<Void>.makeStream()
    let stopped = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func recordStart() {
        lock.withLock { starts += 1 }
        started.continuation.yield(())
    }

    func recordStop() {
        lock.withLock { stops += 1 }
        stopped.continuation.yield(())
    }

    func finish() {
        started.continuation.finish()
        stopped.continuation.finish()
    }
}

/// URLProtocol is configured by class, so its observations are indexed by each test's unique URL.
/// Nothing is registered with URLProtocol globally, and each entry is removed when its test exits.
private nonisolated final class UpdateCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [URL: UpdateCancellationObservation] = [:]

    func insert(_ observation: UpdateCancellationObservation, for url: URL) {
        lock.withLock { observations[url] = observation }
    }

    func observation(for url: URL) -> UpdateCancellationObservation? {
        lock.withLock { observations[url] }
    }

    func remove(_ url: URL) {
        _ = lock.withLock { observations.removeValue(forKey: url) }
    }
}

private nonisolated final class HeldUpdateResponseProtocol: URLProtocol, @unchecked Sendable {
    static let registry = UpdateCancellationRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let observation = Self.registry.observation(for: url),
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "6"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        // Hold the final three bytes and EOF. Cancellation must stop a response already in flight.
        observation.recordStart()
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        Self.registry.observation(for: url)?.recordStop()
    }
}

@Suite("Update transport cancellation")
struct UpdateTransportCancellationTests {
    private nonisolated enum Completion: Equatable, Sendable {
        case cancelled
        case downloaded(URL)
        case failed(String)
    }

    private nonisolated enum MissingEvent: Error {
        case ended(String)
        case timedOut(String)
    }

    /// A timeout bounds failure to receive a positive callback; elapsed time is never success.
    private nonisolated func nextEvent<Value: Sendable>(
        from stream: AsyncStream<Value>, named name: String
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = await iterator.next() else { throw MissingEvent.ended(name) }
                return value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw MissingEvent.timedOut(name)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw MissingEvent.ended(name) }
            return value
        }
    }

    @Test("In-flight URLSession cancellation stops transport and never publishes a package")
    func cancellingAnActiveDownloadStopsTransport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCancellation-\(UUID().uuidString)", isDirectory: true)
        let url = try #require(URL(string: "https://update-cancellation.invalid/\(UUID().uuidString)/Mimic.pkg"))
        let observation = UpdateCancellationObservation()
        HeldUpdateResponseProtocol.registry.insert(observation, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldUpdateResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            HeldUpdateResponseProtocol.registry.remove(url)
            observation.finish()
            try? FileManager.default.removeItem(at: root)
        }
        let release = UpdateRelease(
            version: ReleaseVersion(major: 1, minor: 0, patch: 0),
            tag: "v1.0.0", title: "Mimic 1.0.0", notes: "",
            pageURL: URL(string: "https://example.invalid/release")!, publishedAt: .distantPast,
            asset: .init(
                name: "Mimic.pkg", downloadURL: url, sizeInBytes: 6,
                sha256: "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721"
            )
        )
        let installer = UpdateInstaller(session: session, downloadRoot: root)
        let completion = AsyncStream<Completion>.makeStream()
        let download = Task {
            do {
                let file = try await installer.download(release)
                completion.continuation.yield(.downloaded(file))
            } catch is CancellationError {
                completion.continuation.yield(.cancelled)
            } catch {
                completion.continuation.yield(.failed(error.localizedDescription))
            }
            completion.continuation.finish()
        }
        defer { download.cancel() }

        try await nextEvent(from: observation.started.stream, named: "transport start")
        #expect(observation.startCount == 1)
        download.cancel()
        try await nextEvent(from: observation.stopped.stream, named: "transport stop")
        let result = try await nextEvent(from: completion.stream, named: "download completion")

        #expect(result == .cancelled)
        #expect(observation.stopCount == 1)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
