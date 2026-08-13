import Domain
import Foundation
import SpecImport

/// Adds a reviewed set of import candidates to a project — through `ProjectCommandExecutor`, so an
/// import is held to exactly the rules an edit is.
///
/// This used to build `Scenario` and `Endpoint` inline and append them, which made importing the one
/// way into a project that validated nothing. `ProjectCommandExecutor` guards every edit and
/// `ProjectValidator` guards `projectImport`; that went around both, and `SpecImport` does not
/// validate either — it reports what it read.
///
/// Real captures make that reachable rather than theoretical. A browser writes `"status": 0` into a
/// HAR for every cancelled, blocked or transport-failed request, and a session's worth of traffic
/// normally contains several. Stored verbatim, that 0 reached the serving path, where
/// `VaporConfigurator.clampedStatusCode` answered 200 while the editor showed 0 and flagged the
/// user's own field as invalid — the request and the window disagreeing about the same mock. A
/// response header carrying CR or LF went the same way: accepted here, silently dropped when the
/// response was written, under a comment in `VaporConfigurator` promising that "the validators on the
/// editing and import paths are where a bad header gets a real error message".
///
/// **Values in, values out.** It takes the project to add to and answers with the project to publish
/// and what to say about the candidates it refused; it holds no session, schedules no save and
/// presents nothing. That is what lets the `"Import committer"` suite in
/// `Tests/MimicTests/AppStateAndViewTests.swift` drive the whole pipeline — including the
/// no-project-open, rolled-back and everything-refused paths — without an `AppState`, a store, a
/// `UserDefaults` suite or a running engine anywhere in the test.
///
/// A callback would have worked too and was rejected: publishing is one assignment at one call site,
/// and a returned value is the version a test can assert on directly rather than through a captured
/// variable.
///
/// `nonisolated` because none of this touches the window: it is a transformation of a `MockProject`
/// by a list of candidates, the same opt-out `NavigationHistory` takes for the same reason.
nonisolated struct ImportCommitter {
    /// What the caller should do with the channel it reports import failures on.
    ///
    /// Three states rather than an optional string, because "say nothing at all" and "clear whatever
    /// was there" are different instructions and collapsing them loses one. A commit with nothing
    /// selected must not clear a message the previous command left; a commit in which everything
    /// landed must.
    nonisolated enum Report: Equatable, Sendable {
        /// Nothing was attempted — leave the channel exactly as it is.
        case unchanged
        /// Every selected candidate landed — clear the channel.
        case cleared
        /// Some or all were refused; the text names each route and its reason.
        case skipped(String)

        /// The text to display, or `nil` when there is nothing to say.
        var message: String? {
            guard case let .skipped(text) = self else { return nil }
            return text
        }
    }

    /// The result of a commit: the project to publish, and what to report.
    nonisolated struct Outcome: Equatable, Sendable {
        /// The mutated project, or `nil` when nothing survived — in which case the caller must not
        /// publish, because publishing is what pushes to the engine and restarts the autosave
        /// debounce, and an import in which every candidate was refused should cost neither.
        var project: MockProject?
        var report: Report
    }

    /// The project the candidates are added to. `nil` is the welcome screen, which is refused with a
    /// reason rather than ignored.
    let project: MockProject?

    init(project: MockProject?) {
        self.project = project
    }

    /// Applies the selected candidates to a copy of ``project``.
    ///
    /// One copy, mutated through the executor, answered once at the end.
    ///
    /// Routing this through a per-command `run(_:)` was correct about the rules and wrong about the
    /// cost: every mutating `run` assigns `currentProject`, and that `didSet` applies the whole
    /// project to the engine and reschedules the autosave debounce. A candidate takes two commands,
    /// so a 300-entry HAR — an ordinary size for a real capture — meant six hundred whole-project
    /// pushes to the engine actor and six hundred debounce restarts on the main actor, for one
    /// confirmation of one sheet. The rules still have exactly one implementation: this calls the same
    /// `ProjectCommandExecutor.apply` a single-command edit does.
    ///
    /// Refused candidates are reported, never dropped.
    func commit(_ candidates: [ImportCandidate]) -> Outcome {
        let selected = candidates.filter(\.isSelected)
        guard !selected.isEmpty else { return Outcome(project: nil, report: .unchanged) }

        guard var project = self.project else {
            return Outcome(
                project: nil,
                report: .skipped("Skipped all \(selected.count) imported endpoints: no project is open.")
            )
        }

        var rejections: [String] = []
        var didMutate = false

        for candidate in selected {
            let route = "\(candidate.method.rawValue) \(candidate.path)"

            // Checked before anything is created, because a candidate takes two commands — the
            // endpoint, then its response — and a bad response caught only by the second would leave
            // an endpoint behind still answering the placeholder 200 `makeEndpoint` gives it: a mock
            // nobody captured, standing in for the one they did. These are the same validators the
            // executor calls, so the rule still has a single implementation; only the moment it runs
            // is different.
            if let reason = Self.rejection(for: candidate) {
                rejections.append("\(route) — \(reason)")
                continue
            }

            // Taken before the pair and restored if either half fails. Rolling back by value is what
            // the old `endpointDelete` command was reaching for, and it cannot half-succeed: an
            // endpoint created by the first command but left without its captured response is a mock
            // nobody asked for, standing in for the one they did.
            let beforeCandidate = project

            do {
                guard let created = try ProjectCommandExecutor.apply(
                    .endpointCreate(
                        name: candidate.suggestedName,
                        method: candidate.method,
                        path: candidate.path,
                        // The executor reads an empty string as "clear", which is what a candidate
                        // with no group and no GraphQL operation means.
                        spec: EndpointSpec(
                            groupTag: candidate.suggestedGroupTag ?? "",
                            graphqlOperation: candidate.graphqlOperation ?? ""
                        )
                    ),
                    to: &project
                )?.result.endpoint,
                    let scenarioID = created.activeScenarioID
                else {
                    project = beforeCandidate
                    rejections.append("\(route) — the endpoint could not be created")
                    continue
                }

                _ = try ProjectCommandExecutor.apply(
                    .scenarioUpdate(
                        endpoint: .id(created.id),
                        scenario: .id(scenarioID),
                        spec: ScenarioSpec(
                            name: "Imported",
                            statusCode: candidate.statusCode,
                            headers: candidate.responseHeaders,
                            body: candidate.responseBody,
                            contentType: candidate.responseContentType
                        )
                    ),
                    to: &project
                )
                didMutate = true
            } catch let error as ControlError {
                project = beforeCandidate
                rejections.append("\(route) — \(error.message)")
            } catch {
                project = beforeCandidate
                rejections.append("\(route) — \(error.localizedDescription)")
            }
        }

        // The report is assembled after the loop rather than inside it: every command that succeeds
        // clears the caller's error channel, so a reason recorded mid-import would be erased by the
        // next candidate that lands — which is the silent drop this whole type exists to stop.
        guard !rejections.isEmpty else {
            return Outcome(project: didMutate ? project : nil, report: .cleared)
        }

        let report = """
        Skipped \(rejections.count) of \(selected.count) imported endpoints:

        \(rejections.joined(separator: "\n"))
        """
        return Outcome(project: didMutate ? project : nil, report: .skipped(report))
    }

    /// Why an imported candidate cannot become an endpoint, or `nil` when it can.
    ///
    /// Exactly the three checks `ProjectCommandExecutor` would apply to the two commands
    /// ``commit(_:)`` runs — path on the create, status and headers on the response — run early
    /// enough that a refusal costs no half-made endpoint.
    static func rejection(for candidate: ImportCandidate) -> String? {
        do {
            try EndpointValidator.validatePath(candidate.path)
            try EndpointValidator.validateStatusCode(candidate.statusCode)
            try EndpointValidator.validateHeaders(candidate.responseHeaders)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
