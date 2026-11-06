import Dispatch

/// Runs an async parser to completion from libFuzzer's synchronous callback.
///
/// Errors are the expected outcome for most inputs and are discarded: the fuzzer is looking for
/// crashes, hangs, sanitizer reports and runaway memory, not for rejected documents.
public func runToCompletion(_ operation: @escaping @Sendable () async throws -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task {
        try? await operation()
        done.signal()
    }
    done.wait()
}
