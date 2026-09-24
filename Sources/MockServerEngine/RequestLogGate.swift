import Foundation

/// Limits admitted handlers and logs not yet processed by the consumer. Admission never waits:
/// Vapor has already collected the request body, so suspended handlers would retain unbounded
/// bodies under load. A rejected request has not resolved a route or advanced a journey.
actor RequestLogGate {
    static let capacity = 32

    private var outstanding = 0
    private var isTerminated = false

    var outstandingCount: Int { outstanding }
    func tryAcquireLease() -> RequestLogLease? {
        guard !isTerminated, outstanding < Self.capacity else { return nil }
        outstanding += 1
        return RequestLogLease(gate: self)
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
    private var isOwned = true

    init(gate: RequestLogGate) { self.gate = gate }

    func transferToConsumer() -> Bool {
        lock.withLock {
            guard isOwned else { return false }
            isOwned = false
            return true
        }
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard isOwned else { return false }
            isOwned = false
            return true
        }
        if shouldRelease {
            let gate = gate
            Task { await gate.acknowledge() }
        }
    }

    deinit { release() }
}
