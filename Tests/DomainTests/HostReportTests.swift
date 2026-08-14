import Foundation
import Testing
@testable import Domain

/// The reporting a host-scoped command does *after* it has read its own state.
///
/// Every assertion here used to be unreachable from a test, because the code it covers did not exist
/// as a unit: while the tree carried two hosts, each held its own copy of the server status switch,
/// the state builder, the summary merge and the request-log selection, and the only way to ask
/// either a question was to stand up a repository, an engine or a whole window. The parity suite of
/// that era could check that the two agreed with *each other* — a weaker claim than that either is
/// right, and one that says nothing at all when both are wrong in the same way.
///
/// The second host is deleted now, and these are the assertions about what the answer should *be* —
/// the strong half. `HostCommandSweepTests` covers that `AppControlHost` routes every command to an
/// arm at all; the two together are what "one implementation of the rules" means for the
/// host-scoped minority.
@Suite("Host report")
struct HostReportTests {

    // MARK: - Server status

    /// A stopped server reports the port it *would* serve on and no address, because there is nothing
    /// to point a client at yet. Emitting a `baseURL` here is the specific mistake this pins: it reads
    /// as a live server to anything that branches on the field's presence rather than on `state`.
    @Test("A server that is not running reports its configured port and no address")
    func stoppedServerHasNoBaseURL() {
        for state in [ServerState.stopped, .starting, .stopping] {
            let report = HostReport.serverStatus(state: state, configuredPort: 9099, globalDelayMs: 25)
            #expect(report.port == 9099)
            #expect(report.baseURL == nil, "\(state) reported an address")
            #expect(report.globalDelayMs == 25)
            #expect(report.message == nil)
        }
        #expect(HostReport.serverStatus(state: .stopped, configuredPort: 1, globalDelayMs: 0).state == "stopped")
        #expect(HostReport.serverStatus(state: .starting, configuredPort: 1, globalDelayMs: 0).state == "starting")
        #expect(HostReport.serverStatus(state: .stopping, configuredPort: 1, globalDelayMs: 0).state == "stopping")
    }

    /// A running server reports the port it actually bound, not the one the project is configured
    /// with. The two differ exactly when the configuration was changed under a live server, which is
    /// the case a caller most needs told correctly — it is the one where pointing a client at the
    /// configured port fails.
    @Test("A running server reports the bound port, not the configured one")
    func runningServerReportsTheBoundPort() {
        let report = HostReport.serverStatus(
            state: .running(port: 9222),
            configuredPort: 9099,
            globalDelayMs: 125
        )

        #expect(report.state == "running")
        #expect(report.port == 9222)
        #expect(report.baseURL == "http://127.0.0.1:9222")
        #expect(report.globalDelayMs == 125)
        #expect(report.message == nil)
    }

    /// The failure carries its reason. Dropping `message` here leaves `mimic server status` saying
    /// "error" and nothing else, which is the report that sends somebody to the Console.
    @Test("A failed start reports the reason it failed")
    func errorStateCarriesItsMessage() {
        let report = HostReport.serverStatus(
            state: .error("Port 9099 is already in use."),
            configuredPort: 9099,
            globalDelayMs: 0
        )

        #expect(report.state == "error")
        #expect(report.port == 9099)
        #expect(report.baseURL == nil)
        #expect(report.message == "Port 9099 is already in use.")
    }

    /// Loopback is the contract, not a default: the mock server binds `127.0.0.1` and the control
    /// plane refuses to widen. A `baseURL` naming anything else would send a caller's client off-box.
    @Test("The advertised address is always loopback")
    func baseURLIsLoopback() {
        #expect(HostReport.loopbackBaseURL(port: 8080) == "http://127.0.0.1:8080")
        #expect(
            HostReport.serverStatus(state: .running(port: 8080), configuredPort: 1, globalDelayMs: 0)
                .baseURL == HostReport.loopbackBaseURL(port: 8080)
        )
    }

    // MARK: - Instance state

    /// The three fields derived from the open document. Each host used to derive all three from its
    /// own copy of the expression, against its own notion of "the open project".
    @Test("State counts the open project's endpoints and journeys")
    func stateDerivesCountsFromTheProject() throws {
        var project = MockProject(name: "Checkout")
        _ = try ProjectCommandExecutor.apply(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            to: &project
        )
        _ = try ProjectCommandExecutor.apply(
            .endpointCreate(name: "Logout", method: .post, path: "/logout", spec: nil),
            to: &project
        )
        _ = try ProjectCommandExecutor.apply(.journeyCreate(name: "Flow", spec: nil), to: &project)

        let state = HostReport.state(
            appVersion: "0.9.3",
            mode: "app",
            pid: 4242,
            server: HostReport.serverStatus(state: .stopped, configuredPort: 9099, globalDelayMs: 0),
            project: project,
            activeJourney: nil,
            requestLogCount: 7
        )

        #expect(state.endpointCount == 2)
        #expect(state.journeyCount == 1)
        #expect(state.project?.name == "Checkout")
        #expect(state.project?.id == project.id)
        #expect(state.appVersion == "0.9.3")
        #expect(state.mode == "app")
        #expect(state.pid == 4242)
        #expect(state.requestLogCount == 7)
        // Not a parameter: a caller checks the API contract, not a marketing version, before assuming
        // a command exists — so it comes from `ControlAPI` and no host can answer with its own.
        #expect(state.apiVersion == ControlAPI.version)
    }

    /// With nothing open the counts are zero and the summary is absent — absent, not a zeroed
    /// placeholder, because "no project" and "an empty project" are different answers and a script
    /// branches on which it got.
    @Test("State with no project open omits the summary and counts nothing")
    func stateWithNoProjectOpen() {
        let state = HostReport.state(
            appVersion: nil,
            mode: "headless",
            pid: 1,
            server: HostReport.serverStatus(state: .stopped, configuredPort: 8080, globalDelayMs: 0),
            project: nil,
            activeJourney: nil,
            requestLogCount: 0
        )

        #expect(state.project == nil)
        #expect(state.endpointCount == 0)
        #expect(state.journeyCount == 0)
        // Not passed, so absent — and absent means the on-disk store, not "nobody asked".
        #expect(state.storeFailure == nil)
        #expect(state.storeIsEphemeral == false)
    }

    /// The degraded-store fact travels. The in-memory fallback used to be surfaced only by the
    /// window's alert, so a headless session on a locked store ran fully ephemeral while every
    /// command exited 0 and `mimic state` looked healthy; this report is the only channel a caller
    /// with no window has.
    @Test("State carries the reason the session's store is in memory")
    func stateCarriesTheStoreFailure() {
        let state = HostReport.state(
            appVersion: nil,
            mode: "headless",
            pid: 1,
            server: HostReport.serverStatus(state: .stopped, configuredPort: 8080, globalDelayMs: 0),
            project: nil,
            activeJourney: nil,
            requestLogCount: 0,
            storeFailure: "The database is locked."
        )

        #expect(state.storeFailure == "The database is locked.")
        #expect(state.storeIsEphemeral)
    }

    /// The field is optional on the wire, asserted through `ControlCoding` — the pair
    /// `ControlServer` encodes with and `ControlClient` decodes with. A healthy state encodes no
    /// key at all, so presence is what a script tests; and a payload from an instance that
    /// predates the field decodes as "on disk" rather than failing the whole state.
    @Test("The store failure is present exactly when the store is ephemeral")
    func storeFailureIsOptionalOnTheWire() throws {
        func state(storeFailure: String?) -> ControlState {
            HostReport.state(
                appVersion: nil,
                mode: "headless",
                pid: 1,
                server: HostReport.serverStatus(state: .stopped, configuredPort: 8080, globalDelayMs: 0),
                project: nil,
                activeJourney: nil,
                requestLogCount: 0,
                storeFailure: storeFailure
            )
        }

        let healthy = try ControlCoding.string(ControlResult(state: state(storeFailure: nil)))
        #expect(healthy.contains("storeFailure") == false)

        let degraded = try ControlCoding.string(ControlResult(state: state(storeFailure: "The database is locked.")))
        #expect(degraded.contains(#""storeFailure":"The database is locked.""#))

        // The healthy payload is byte-for-byte what an instance without the field answers with,
        // so decoding it is the backward-compatibility check.
        let decoded = try ControlCoding.decode(ControlResult.self, from: Data(healthy.utf8))
        #expect(decoded.state?.storeFailure == nil)

        let roundTripped = try ControlCoding.decode(ControlResult.self, from: Data(degraded.utf8))
        #expect(roundTripped.state?.storeFailure == "The database is locked.")
    }

    // MARK: - Project listing

    /// `allProjects()` returns stubs with no children, so a listing that trusted them would report
    /// zero endpoints for every project. The counts come from the store's grouped query and are
    /// merged here.
    @Test("A listing merges the store's counts onto the stubs")
    func summariesTakeTheirCountsFromTheStore() {
        let first = MockProject(name: "Checkout", serverConfiguration: ServerConfiguration(port: 9099, globalDelayMs: 25))
        let second = MockProject(name: "Empty")

        let summaries = HostReport.projectSummaries(
            of: [first, second],
            counts: [first.id: ProjectCounts(endpoints: 3, journeys: 2)]
        )

        #expect(summaries.map(\.name) == ["Checkout", "Empty"], "the store's order is the listing's order")
        #expect(summaries[0].endpointCount == 3)
        #expect(summaries[0].journeyCount == 2)
        // Its own port and delay, not `ServerConfiguration.default`. The window's listing used to
        // invent both for every project it did not have open, so a script that listed projects to
        // find the port to point a client at was handed 8080 for all of them.
        #expect(summaries[0].port == 9099)
        #expect(summaries[0].globalDelayMs == 25)

        // A project with neither child has no row in `counts`, and the stub's own zeroes are already
        // the right answer — not a reason to drop it from the listing.
        #expect(summaries[1].endpointCount == 0)
        #expect(summaries[1].journeyCount == 0)
    }

    /// The window's one legitimate asymmetry: an edit made a moment ago is still in the autosave
    /// debounce, so for the open project the session is ahead of the store.
    @Test("The open project is reported from the session, and only that one is")
    func theOpenProjectOverlaysTheStoredRow() throws {
        var open = MockProject(name: "Checkout", serverConfiguration: ServerConfiguration(port: 9099, globalDelayMs: 0))
        _ = try ProjectCommandExecutor.apply(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
            to: &open
        )
        // The stub the store still holds: same id, none of the edit.
        let stale = MockProject(id: open.id, name: "Checkout")
        let other = MockProject(name: "Other")

        let summaries = HostReport.projectSummaries(
            of: [stale, other],
            counts: [other.id: ProjectCounts(endpoints: 5, journeys: 4)],
            openProject: open
        )

        #expect(summaries[0].endpointCount == 1, "the open project was answered from the stale stub")
        #expect(summaries[0].port == 9099)
        // The overlay applies to the open project alone. Applying it to every row would report one
        // project's counts for all of them.
        #expect(summaries[1].name == "Other")
        #expect(summaries[1].endpointCount == 5)
        #expect(summaries[1].journeyCount == 4)
    }

    /// No overlay is the case for a caller whose store is never behind its session — a host that
    /// saves before it answers passes `nil` here.
    @Test("With no open project the listing is the store, unmodified")
    func summariesWithoutAnOverlay() {
        let stored = MockProject(name: "Checkout")
        let summaries = HostReport.projectSummaries(of: [stored], counts: [:])
        #expect(summaries.count == 1)
        #expect(summaries[0].id == stored.id)
        #expect(summaries[0].endpointCount == 0)
    }

    // MARK: - Request log

    private static func log(_ path: String, outcome: RequestOutcome) -> RequestLog {
        RequestLog(method: .get, path: path, outcome: outcome)
    }

    /// **Filter, then limit.** `--limit 2 --unmatched` means "the last 2 requests I have no mock
    /// for", not "whichever of the last 2 happened to be unmatched".
    ///
    /// The fixture is built so the two orders cannot both pass: the only unmatched entry is the
    /// *first* of four, so limiting first drops it and answers with nothing at all.
    @Test("Unmatched entries are filtered before the limit is applied")
    func filteringHappensBeforeTheLimit() {
        let logs = [
            Self.log("/missing", outcome: .unmatched),
            Self.log("/a", outcome: .endpoint),
            Self.log("/b", outcome: .endpoint),
            Self.log("/c", outcome: .journey),
        ]

        let selected = HostReport.requestLog(from: logs, limit: 2, unmatchedOnly: true)

        #expect(selected.count == 1, "the limit was applied before the filter")
        #expect(selected.first?.path == "/missing")
    }

    /// The limit takes the *most recent* entries. Taking the first two would answer a `--limit`
    /// against a thousand-entry log with the oldest traffic in it.
    @Test("A limit takes the newest entries")
    func limitTakesTheSuffix() {
        let logs = [Self.log("/1", outcome: .endpoint), Self.log("/2", outcome: .endpoint), Self.log("/3", outcome: .endpoint)]
        #expect(HostReport.requestLog(from: logs, limit: 2, unmatchedOnly: nil).map(\.path) == ["/2", "/3"])
        #expect(HostReport.requestLog(from: logs, limit: nil, unmatchedOnly: nil).map(\.path) == ["/1", "/2", "/3"])
        #expect(HostReport.requestLog(from: logs, limit: 0, unmatchedOnly: nil).isEmpty)
        // Floored rather than refused: a caller asking for -1 entries gets none, not an error about
        // arithmetic, and `Array.suffix` would trap on a negative count.
        #expect(HostReport.requestLog(from: logs, limit: -5, unmatchedOnly: nil).isEmpty)
    }

    /// `unmatchedOnly` is `Bool?` on the wire, and only `true` filters. `false` and an omitted field
    /// are the same request — "everything" — which is what `nil` has to mean for a CLI flag that is
    /// simply absent.
    @Test("Only an explicit true filters")
    func unmatchedOnlyIsOptIn() {
        let logs = [Self.log("/missing", outcome: .unmatched), Self.log("/a", outcome: .endpoint)]
        #expect(HostReport.requestLog(from: logs, limit: nil, unmatchedOnly: nil).count == 2)
        #expect(HostReport.requestLog(from: logs, limit: nil, unmatchedOnly: false).count == 2)
        #expect(HostReport.requestLog(from: logs, limit: nil, unmatchedOnly: true).count == 1)
    }

    /// **Redaction is not optional.** `logList` is the one command that hands captured traffic to
    /// somebody else, and the traffic is the app-under-test's real credentials. It is applied here so
    /// that no host arm can answer with a less redacted log than this shared code decides.
    @Test("Credentials are redacted on the way out, and the held log is left intact")
    func credentialsAreRedacted() throws {
        let entry = RequestLog(
            method: .post,
            path: "/login",
            requestHeaders: ["Authorization": "Bearer secret-token", "Accept": "application/json"],
            responseHeaders: ["Set-Cookie": "session=abc123", "Content-Type": "application/json"],
            outcome: .endpoint
        )

        let selected = try #require(HostReport.requestLog(from: [entry], limit: nil, unmatchedOnly: nil).first)

        #expect(selected.requestHeaders["Authorization"] == RequestLog.redactionPlaceholder)
        #expect(selected.responseHeaders["Set-Cookie"] == RequestLog.redactionPlaceholder)
        // The name survives — "there was an Authorization header" is often the fact being debugged.
        #expect(selected.requestHeaders["Accept"] == "application/json")
        #expect(selected.responseHeaders["Content-Type"] == "application/json")

        // The redaction produced a *new* value rather than editing the one it was handed — which is
        // what "the host's own copy is untouched" actually rests on, and the thing worth asserting.
        // Comparing `entry` to its own literal would pass by Swift's value semantics whatever this
        // function did, so it asserts nothing about `HostReport`.
        #expect(selected.requestHeaders["Authorization"] != entry.requestHeaders["Authorization"])
    }
}

/// The control replies' stable vocabulary, asserted against the words themselves.
///
/// A comparison between two producers of a sentence cannot tell a shared sentence that is right
/// from a shared sentence that is wrong — which is what the old two-host parity suite was limited
/// to. These pin the words a script actually string-matches on.
@Suite("Control messages")
struct ControlMessagesTests {

    @Test("Ping names the API contract, the mode and the process")
    func pingNamesTheInstance() {
        #expect(
            ControlMessages.ping(mode: "headless", pid: 4242)
                == "Mimic control plane \(ControlAPI.version) (headless, pid 4242)."
        )
        #expect(ControlMessages.ping(mode: "app", pid: 1).contains("(app, pid 1)"))
    }

    /// The pluralisation lived in both hosts, and a count of one is the case a hand-written sentence
    /// gets wrong.
    @Test("Clearing the log counts what it cleared, in the singular when there was one")
    func logClearedPluralises() {
        #expect(ControlMessages.logCleared(count: 0) == "Cleared 0 request log entries.")
        #expect(ControlMessages.logCleared(count: 1) == "Cleared 1 request log entry.")
        #expect(ControlMessages.logCleared(count: 12) == "Cleared 12 request log entries.")
    }

    @Test("Server lifecycle answers come from one vocabulary")
    func serverSentences() {
        #expect(ControlMessages.serverAlreadyRunning(port: 9099) == "Server already running on port 9099.")
        #expect(ControlMessages.serverNotRunning == "Server is not running.")
    }

    @Test("Journey runtime answers come from one vocabulary")
    func journeySentences() {
        #expect(
            ControlMessages.journeyActivated(name: "Retry after failure", stepCount: 4)
                == "Activated journey \"Retry after failure\" (4 steps)."
        )
        #expect(ControlMessages.journeyRestarted(name: "Flow") == "Restarted journey \"Flow\".")
        #expect(
            ControlMessages.journeyCleared
                == "Cleared the active journey; endpoints now answer directly."
        )
    }

    /// The declared contract difference, and the reason it is written as two functions over one
    /// sentence: only the verb may differ. The counted tail drifting between the hosts is the failure
    /// this shape forecloses.
    @Test("Import differs from the service only in its verb")
    func importDiffersOnlyInTense() {
        let importing = ControlMessages.projectImporting(name: "Fixture", endpointCount: 3, journeyCount: 1)
        let imported = ControlMessages.projectImported(name: "Fixture", endpointCount: 3, journeyCount: 1)

        #expect(importing == "Importing project \"Fixture\" (3 endpoints, 1 journeys).")
        #expect(imported == "Imported project \"Fixture\" (3 endpoints, 1 journeys).")
        #expect(
            importing.dropFirst("Importing".count) == imported.dropFirst("Imported".count),
            "the two tenses have drifted apart in more than the verb"
        )
    }
}

/// Resolving a `ProjectRef` — the lookup the host does before it touches a project by name.
///
/// It was a private copy in each of the two hosts the tree used to carry: two copies of "which
/// failure does a reference that names nothing produce" is two chances to answer `project.notFound`
/// for a lookup that never happened.
@Suite("Project reference resolution")
struct ProjectReferenceTests {

    private static let checkout = MockProject(name: "Checkout")
    private static let billing = MockProject(name: "Billing")

    @Test("A name resolves case-insensitively and after trimming")
    func namesFoldAndTrim() throws {
        let stored = [Self.checkout, Self.billing]
        #expect(try MockProject.requireNamed(.name("checkout"), in: stored).id == Self.checkout.id)
        #expect(try MockProject.requireNamed(.name("  CHECKOUT  "), in: stored).id == Self.checkout.id)
        #expect(try MockProject.requireNamed(.name("Billing"), in: stored).id == Self.billing.id)
    }

    /// When several projects share a name the first declared wins, matching how the request matcher
    /// breaks ties. Deterministic beats "whichever the store happened to return second".
    @Test("A duplicate name resolves to the first declared")
    func duplicateNamesResolveToTheFirst() throws {
        let first = MockProject(name: "Checkout")
        let second = MockProject(name: "checkout")
        #expect(try MockProject.requireNamed(.name("Checkout"), in: [first, second]).id == first.id)
    }

    /// Nothing was searched for, so `project.notFound` would describe a lookup that never happened.
    ///
    /// `do`/`catch` rather than `#expect(throws:)` so the *code* is asserted rather than the type:
    /// both dead ends here throw a `ControlError`, and which one is the whole point.
    @Test("A reference naming nothing is refused as a bad request, not as a missing project")
    func anEmptyReferenceIsABadRequest() {
        for ref in [ProjectRef(), ProjectRef(name: ""), ProjectRef(name: "   ")] {
            do {
                let resolved = try MockProject.requireNamed(ref, in: [Self.checkout])
                Issue.record("\(ref) resolved to \(resolved.name) instead of being refused")
            } catch let error as ControlError {
                #expect(error == ControlError.projectReferenceRequired, "\(ref) was refused as \(error.code)")
            } catch {
                Issue.record("\(ref) failed with a non-ControlError: \(error)")
            }
        }
        #expect(ControlError.projectReferenceRequired.code == "request.invalid")
        #expect(ControlError.projectReferenceRequired.message == "Provide a project id or name.")
    }

    /// A name that matched nothing *is* a missing project, and the error carries the name so a caller
    /// can print it back.
    @Test("A name that matches nothing reports the project as missing")
    func anUnmatchedNameIsNotFound() {
        do {
            let resolved = try MockProject.requireNamed(.name("Nonexistent"), in: [Self.checkout])
            Issue.record("an unknown name resolved to \(resolved.name)")
        } catch let error as ControlError {
            #expect(error.code == "project.notFound")
            #expect(error.details?["name"] == "Nonexistent")
        } catch {
            Issue.record("failed with a non-ControlError: \(error)")
        }
    }

    /// The open-project shortcut. `projectCreate` answers before its write lands on the window's
    /// host, so a script that creates a project and immediately names it has to resolve against the
    /// session rather than the store.
    @Test("A project matches the reference that names it")
    func matchesNamesTheProject() {
        #expect(Self.checkout.matches(.id(Self.checkout.id)))
        #expect(Self.checkout.matches(.id(Self.billing.id)) == false)
        #expect(Self.checkout.matches(.name("checkout")))
        #expect(Self.checkout.matches(.name("  CHECKOUT ")))
        #expect(Self.checkout.matches(.name("Billing")) == false)
        // An id decides on its own: a reference carrying both is answered by the id, so a stale name
        // cannot steer it to another project.
        #expect(Self.checkout.matches(ProjectRef(id: Self.checkout.id, name: "Billing")))
        // A reference naming nothing matches nothing — it names no project, so it cannot name this one.
        #expect(Self.checkout.matches(ProjectRef()) == false)
        #expect(Self.checkout.matches(.name("   ")) == false)
    }

    /// The two lookups agree about the same reference, which is the property that makes it safe for a
    /// host to try the open project first and fall through to the store: whichever project the store
    /// resolves a reference to is the one — the only one — that reference matches.
    ///
    /// They are still two implementations of "same name", because the shortcut compares with
    /// `caseInsensitiveCompare` and the lookup folds with `lowercased()`. That difference is
    /// pre-existing and deliberately left alone rather than unified in a consolidation pass; this is
    /// what checks the two have not started disagreeing about a reference a caller would really send.
    @Test("The open-project shortcut and the store lookup pick the same project")
    func theTwoLookupsAgree() throws {
        let stored = [Self.checkout, Self.billing]
        for ref in [ProjectRef.name("checkout"), .name("  Checkout "), .name("BILLING")] {
            let resolved = try MockProject.requireNamed(ref, in: stored)
            #expect(resolved.matches(ref), "the store resolved \(ref) to a project that does not match it")
            for other in stored where other.id != resolved.id {
                #expect(other.matches(ref) == false, "\(ref) matches \(other.name) as well")
            }
        }
    }
}
