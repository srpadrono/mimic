import Foundation

/// The sentences a control reply is made of, held apart from any host.
///
/// A command's *reply* is part of its contract: a script string-matches on it, so the wording is a
/// stable surface, and AGENTS.md's rule about implementing a rule once is not only about the
/// mutation — it is about everything the caller can observe. `ProjectCommandExecutor` already
/// guarantees this for the project-scoped majority, because those commands have exactly one
/// implementation. This type is the same guarantee for the host-scoped minority's wording, and it
/// was born of the failure mode it prevents: while the tree carried two hosts, each spelled these
/// sentences out privately, and one reported `Reset 12 log entries and journey "Checkout"` where
/// the other reported `Reset all.` The second host is deleted; the discipline stays, because "the
/// arm's own wording" versus "the vocabulary" is a real boundary even with one host — a reply built
/// here cannot drift when somebody rewrites an arm.
///
/// Only the parts that are a pure function of what happened live here. What a host genuinely does —
/// persist, mutate a session, await an engine — is its own, and stays beside the state it touches.
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
    /// this is a success rather than a collision.
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

    /// The two tenses of the import reply, spelled as two functions over one sentence so the tail
    /// cannot be written twice.
    ///
    /// The verb is a fact about the caller's save. The shipped host answers `projectImporting` —
    /// its save is a task in the write chain, so it can only report what it *accepted* — while a
    /// host that awaits its store before answering reports `projectImported`, what it *stored*.
    /// Nothing in production says the past tense today (the second host that did is deleted;
    /// `ControlServerTests`' fixture, which saves synchronously in memory, still does), and the pair
    /// is kept because the distinction is the honest one: if the window's import reply is ever made
    /// to await the chain, the change is one verb here rather than a resworded sentence there.
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
