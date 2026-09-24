/// Limits logs that have been published but not yet processed by the single consumer.
/// A reservation is handed directly to the next waiter when an entry is acknowledged, so
/// cancellation of a request cannot leave an acquired permit behind. A waiting request still
/// publishes its log after cancellation: losing that entry could also lose automatic capture.
actor RequestLogGate {
    static let capacity = 32

    private var outstanding = 0
    // Two stacks form a FIFO without shifting every remaining waiter on each acknowledgment.
    private var incomingWaiters: [CheckedContinuation<Bool, Never>] = []
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var isTerminated = false

    var outstandingCount: Int { outstanding }
    var waitingCount: Int { incomingWaiters.count + readyWaiters.count }

    func reserve() async -> Bool {
        guard !isTerminated else { return false }
        if outstanding < Self.capacity {
            outstanding += 1
            return true
        }
        return await withCheckedContinuation { incomingWaiters.append($0) }
    }

    func acknowledge() {
        guard outstanding > 0 else { return }
        if !isTerminated, waitingCount > 0 {
            if readyWaiters.isEmpty {
                readyWaiters = Array(incomingWaiters.reversed())
                incomingWaiters.removeAll()
            }
            readyWaiters.removeLast().resume(returning: true)
        } else {
            outstanding -= 1
        }
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        for waiter in readyWaiters { waiter.resume(returning: false) }
        for waiter in incomingWaiters { waiter.resume(returning: false) }
        readyWaiters.removeAll()
        incomingWaiters.removeAll()
    }
}
