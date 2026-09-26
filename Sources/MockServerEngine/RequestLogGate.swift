import Foundation

/// Limits active handlers and logs not yet processed by the consumer. Admission never waits,
/// and streamed request bodies are explicitly collected only after taking a slot. A rejected
/// request has not resolved a route or advanced a journey.
actor RequestLogGate {
    /// Bounded concurrent handlers. Logs are allowed a larger short-lived backlog while the
    /// app's main actor updates its request list and performs automatic capture.
    static let capacity = 32
    static let pendingLogCapacity = 64

    private var activeRequests = 0
    private var outstanding = 0
    private var isTerminated = false

    var activeCount: Int { activeRequests }
    var outstandingCount: Int { outstanding }
    func tryAcquireLease() -> RequestLogLease? {
        guard !isTerminated, activeRequests < Self.capacity,
              outstanding < Self.pendingLogCapacity else { return nil }
        activeRequests += 1
        outstanding += 1
        return RequestLogLease(gate: self)
    }

    func finishRequest(releaseUnpublishedLog: Bool) {
        guard activeRequests > 0 else { return }
        activeRequests -= 1
        if releaseUnpublishedLog, outstanding > 0 { outstanding -= 1 }
    }

    func acknowledge() {
        guard outstanding > 0 else { return }
        outstanding -= 1
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
    }
}

/// Owns an admitted request's slot until its log is handed to the consumer.
/// If Vapor never starts its body writer, dropping the response drops this lease and
/// returns the slot. The lock makes a late cancellation/deinit safe alongside logging.
final class RequestLogLease: @unchecked Sendable {
    private let gate: RequestLogGate
    private let lock = NSLock()
    private var isActive = true
    private var ownsLog = true

    init(gate: RequestLogGate) { self.gate = gate }

    func transferToConsumer() -> Bool {
        lock.withLock {
            guard isActive, ownsLog else { return false }
            ownsLog = false
            return true
        }
    }

    private func takeRelease() -> Bool? {
        lock.withLock { () -> Bool? in
            guard isActive else { return nil }
            isActive = false
            let unpublished = ownsLog
            ownsLog = false
            return unpublished
        }
    }

    /// A completed handler can return its slot before accepting another request. `release()`
    /// remains synchronous for response writers and deinit, where awaiting is impossible.
    func finish() async {
        if let unpublishedLog = takeRelease() {
            await gate.finishRequest(releaseUnpublishedLog: unpublishedLog)
        }
    }

    func release() {
        let unpublishedLog = takeRelease()
        if let unpublishedLog {
            let gate = gate
            Task { await gate.finishRequest(releaseUnpublishedLog: unpublishedLog) }
        }
    }

    deinit { release() }
}
