/// Combines the configured network delay with an endpoint or journey-step delay.
enum ResponseDelay {
    static func combined(globalMs: Int, localMs: Int) -> Int {
        let global = max(0, globalMs)
        let local = max(0, localMs)
        let (sum, overflow) = global.addingReportingOverflow(local)
        return overflow ? Int.max : sum
    }
}
