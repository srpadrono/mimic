import Foundation

/// Limits active handlers and logs not yet processed by the consumer. Admission never waits:
/// Vapor has already collected the request body, so suspended handlers would retain unbounded
/// bodies under load. A rejected request has not resolved a route or advanced a journey.
actor RequestLogGate {
    static let capacity = 32

    private var activeRequests = 0
    private var outstanding = 0
    private var isTerminated = false

    var activeCount: Int { activeRequests }
    var outstandingCount: Int { outstanding }
    func tryAcquireLease() -> RequestLogLease? {
        guard !isTerminated, activeRequests < Self.capacity,
              outstanding < Self.capacity else { return nil }
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

    func release() {
        let unpublishedLog = lock.withLock { () -> Bool? in
            guard isActive else { return nil }
            isActive = false
            let unpublished = ownsLog
            ownsLog = false
            return unpublished
        }
        if let unpublishedLog {
            let gate = gate
            Task { await gate.finishRequest(releaseUnpublishedLog: unpublishedLog) }
        }
    }

    deinit { release() }
}
