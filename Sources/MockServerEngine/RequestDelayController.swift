import Foundation

/// One server run owns the artificial delays for all of its listeners. Stopping that run wakes
/// its handlers without canceling a later run or changing the shared request-log accounting.
actor RequestDelayController {
    private var sleepers: [UUID: Task<Void, Error>] = [:]
    private var isStopped = false

    func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        guard milliseconds > 0 else { return }

        let id = UUID()
        let sleeper = Task { try await Task.sleep(for: .milliseconds(milliseconds)) }
        sleepers[id] = sleeper
        defer { sleepers.removeValue(forKey: id) }

        try await withTaskCancellationHandler {
            try await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        // A stop can race the timer completing. Even then, the handler must not send its
        // configured success after this run has been stopped.
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
    }

    func cancel() {
        isStopped = true
        for sleeper in sleepers.values { sleeper.cancel() }
        sleepers.removeAll()
    }
}
