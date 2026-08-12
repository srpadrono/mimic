import Foundation

/// Sentences both hosts have to say identically.
///
/// A command's *reply* is part of its contract: a script that runs `mimic reset` against a running
/// window and against a headless daemon is entitled to the same answer, and AGENTS.md's rule about
/// implementing a rule once is not only about the mutation — it is about everything the caller can
/// observe. `ProjectCommandExecutor` already guarantees this for the project-scoped majority, because
/// those commands have exactly one implementation. The genuinely stateful minority is implemented
/// twice by necessity, and that is where the wording drifted: the service reported
/// `Reset 12 log entries and journey "Checkout"` while the window reported `Reset all.`
///
/// Only the parts that are a pure function of what happened live here. What the two hosts genuinely
/// do differently — one persists through a repository and awaits, the other mutates a live session
/// and returns — stays split, and staying split is easier to see once the accidental differences are
/// gone.
public enum ControlMessages {

    /// What a `reset` reports, from what it actually cleared.
    ///
    /// - Parameters:
    ///   - clearedLogEntries: how many entries were removed, or `nil` if the log was out of scope.
    ///   - restartedJourneyName: the journey rewound to step one, or `nil` if none was.
    public static func reset(clearedLogEntries: Int?, restartedJourneyName: String?) -> String {
        var cleared: [String] = []
        if let clearedLogEntries {
            cleared.append("\(clearedLogEntries) log \(clearedLogEntries == 1 ? "entry" : "entries")")
        }
        if let restartedJourneyName {
            cleared.append("journey \"\(restartedJourneyName)\"")
        }
        // Naming what was cleared rather than the scope that was asked for. "Reset all." is true of
        // the request and says nothing about the instance — a caller learns that its own command
        // parsed, which it already knew.
        //
        // A count of zero is still an answer, so `--scope all` on an idle instance reports
        // "Reset 0 log entries." rather than "Nothing to reset.": the log was in scope and is now
        // empty, and that is a different fact from the log never having been looked at. Only a scope
        // whose every target reported nothing back — `--scope journey` with no journey active —
        // leaves `cleared` empty.
        return cleared.isEmpty ? "Nothing to reset." : "Reset \(cleared.joined(separator: " and "))."
    }
}
