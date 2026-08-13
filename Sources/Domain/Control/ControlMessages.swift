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

    // MARK: - Discovery

    /// What `mimic ping` answers.
    ///
    /// `mode` and `pid` are the two facts that make the reply worth reading — *which* Mimic answered,
    /// and whether it has a window. Both are the host's to know; the sentence around them is not.
    public static func ping(mode: String, pid: Int) -> String {
        "Mimic control plane \(ControlAPI.version) (\(mode), pid \(pid))."
    }

    // MARK: - Server lifecycle

    /// A start against an instance already bound to the port asked for.
    ///
    /// Benign on purpose: a script that ensures the server is up should not have to ask first, so
    /// this is a success from both hosts rather than a collision.
    public static func serverAlreadyRunning(port: Int) -> String {
        "Server already running on port \(port)."
    }

    /// A stop with nothing bound. Also a success — there is nothing to do and it has been done.
    public static let serverNotRunning = "Server is not running."

    // MARK: - Journeys

    /// Deactivation. Says what changes rather than what was unset, because the observable effect —
    /// endpoints answering directly again — is what the caller is actually asking about.
    public static let journeyCleared = "Cleared the active journey; endpoints now answer directly."

    public static func journeyActivated(name: String, stepCount: Int) -> String {
        "Activated journey \"\(name)\" (\(stepCount) steps)."
    }

    public static func journeyRestarted(name: String) -> String {
        "Restarted journey \"\(name)\"."
    }

    // MARK: - Logs

    public static func logCleared(count: Int) -> String {
        "Cleared \(count) request log \(count == 1 ? "entry" : "entries")."
    }

    // MARK: - Project import

    /// The two tenses of the import reply.
    ///
    /// This is the one place a difference between the hosts is deliberate, so it is spelled as two
    /// functions over one sentence rather than hidden behind a flag: the headless service awaits its
    /// repository and can report what it stored, the window's save is a task and can only report what
    /// it accepted. `HostParityTests.contractDifferences` records the difference; what the pair here
    /// removes is the *rest* of the sentence being written twice. The two tails agreed when this was
    /// written, and nothing would have noticed if they stopped: `message` is an allowed difference
    /// for this command in `HostParityTests` precisely because of the verb, so the comparison that
    /// would have caught a drifting tail is the one turned off for it.
    public static func projectImported(name: String, endpointCount: Int, journeyCount: Int) -> String {
        projectImport(
            verb: "Imported",
            name: name,
            endpointCount: endpointCount,
            journeyCount: journeyCount
        )
    }

    public static func projectImporting(name: String, endpointCount: Int, journeyCount: Int) -> String {
        projectImport(
            verb: "Importing",
            name: name,
            endpointCount: endpointCount,
            journeyCount: journeyCount
        )
    }

    private static func projectImport(
        verb: String,
        name: String,
        endpointCount: Int,
        journeyCount: Int
    ) -> String {
        "\(verb) project \"\(name)\" (\(endpointCount) endpoints, \(journeyCount) journeys)."
    }
}
