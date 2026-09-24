/// One finite budget for a served response, including a timeout hold after any configured delay.
/// Direct engine callers and older stored projects may bypass validation; serving clamps those
/// values so they cannot occupy an admission slot indefinitely.
public enum ResponseDelay {
    public static let maximumMilliseconds = 300_000
    public static let maximumDescription = "300000 ms (5 minutes)"

    public static func isWithinLimit(globalMs: Int, localMs: Int = 0, holdMs: Int = 0) -> Bool {
        guard globalMs >= 0, localMs >= 0, holdMs >= 0,
              globalMs <= maximumMilliseconds,
              localMs <= maximumMilliseconds - globalMs else { return false }
        return holdMs <= maximumMilliseconds - globalMs - localMs
    }

    /// Saturating addition with the same cap as validation, including negative legacy inputs.
    public static func combined(globalMs: Int, localMs: Int, holdMs: Int = 0) -> Int {
        var remaining = maximumMilliseconds
        var total = 0
        for value in [globalMs, localMs, holdMs] {
            let accepted = min(max(0, value), remaining)
            total += accepted
            remaining -= accepted
        }
        return total
    }
}
