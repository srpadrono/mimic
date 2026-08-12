import Foundation
import Testing
import Domain
import Persistence
import SpecImport
@testable import AppFeatures

/// The import commit path — the third way into a project, and the one that used to check nothing.
///
/// Editing goes through `ProjectCommandExecutor`, which validates the path, the status code and the
/// headers; a whole imported document goes through `ProjectValidator`. `commitImportedCandidates`
/// built `Endpoint` and `Scenario` inline and appended them, so a capture was the one route by which
/// a value the editor would refuse to accept could reach the store — and `SpecImport` does not
/// validate either, because its job is to report what it read.
///
/// The two cases below are what a real capture actually contains, not what a fixture usually does:
/// a status a browser writes for a request that never completed, and a header value that would split
/// the response Mimic writes.
@Suite("Import commit")
@MainActor
struct ImportCommitTests {

    private func makeAppState() throws -> AppState {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        // Its own suite per test, so a run cannot read — or overwrite — the developer's recents.
        let defaults = try #require(UserDefaults(suiteName: "ImportCommitTests.\(UUID().uuidString)"))
        return AppState(
            projectRepository: repository,
            recentProjectsStore: RecentProjectsStore(defaults: defaults)
        )
    }

    private func makeAppStateWithProject() throws -> AppState {
        let appState = try makeAppState()
        appState.createProject(name: "Capture", port: 8099)
        return appState
    }

    private func candidate(
        method: HTTPMethod = .get,
        path: String = "/v1/things",
        statusCode: Int = 200,
        headers: [String: String] = ["X-Trace": "abc"],
        isSelected: Bool = true
    ) -> ImportCandidate {
        ImportCandidate(
            isSelected: isSelected,
            method: method,
            path: path,
            suggestedName: "Get Things",
            suggestedGroupTag: "Things",
            statusCode: statusCode,
            responseHeaders: headers,
            responseBody: #"{"ok":true}"#,
            responseContentType: .json,
            bodySizeBytes: 11,
            bodySizeExceedsLimit: false,
            isDuplicate: false
        )
    }

    @Test("A selected candidate lands whole; an unselected one is left alone")
    func selectedCandidatesLandComplete() throws {
        let appState = try makeAppStateWithProject()

        appState.commitImportedCandidates([
            candidate(),
            candidate(method: .delete, path: "/v1/things/1", isSelected: false),
        ])

        let endpoints = try #require(appState.currentProject?.endpoints)
        #expect(endpoints.count == 1)

        // Routing the commit through two commands must not lose any field the inline construction
        // used to set — the group tag and the active scenario are the two that are easiest to drop.
        let endpoint = try #require(endpoints.first)
        #expect(endpoint.name == "Get Things")
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/v1/things")
        #expect(endpoint.groupTag == "Things")

        let scenario = try #require(endpoint.scenarios.first)
        #expect(endpoint.activeScenarioID == scenario.id)
        #expect(scenario.name == "Imported")
        #expect(scenario.statusCode == 200)
        #expect(scenario.headers["X-Trace"] == "abc")
        #expect(scenario.body == #"{"ok":true}"#)
        #expect(scenario.bodyContentType == .json)
        #expect(appState.lastCommandError == nil)
    }

    @Test("A request the browser never completed is refused rather than stored as status 0")
    func cancelledCaptureIsRefused() throws {
        let appState = try makeAppStateWithProject()

        // What Chrome, Safari and Firefox all write for a cancelled, blocked or transport-failed
        // request. Stored, it served 200 through `clampedStatusCode` while the editor showed 0 and
        // flagged the user's own field as invalid.
        appState.commitImportedCandidates([candidate(path: "/v1/cancelled", statusCode: 0)])

        #expect(
            appState.currentProject?.endpoints.isEmpty == true,
            "an endpoint answering a placeholder 200 is worse than no endpoint"
        )
        let error = try #require(appState.lastCommandError, "a refusal must be reported, not dropped")
        #expect(error.contains("GET /v1/cancelled"), "the message has to name which candidate")
        #expect(error.contains("Invalid status code: 0"))
    }

    @Test("A response header carrying CRLF is refused instead of being dropped at serve time")
    func headerSplittingValueIsRefused() throws {
        let appState = try makeAppStateWithProject()

        // A CR/LF in a value ends the header, and everything after the break is read by the client
        // as further headers. `VaporConfigurator` drops it silently when the response is written,
        // under a comment promising that the import path is where it gets a real error message.
        appState.commitImportedCandidates([
            candidate(headers: ["X-Trace": "abc\r\nSet-Cookie: session=stolen"]),
        ])

        #expect(appState.currentProject?.endpoints.isEmpty == true)
        let error = try #require(appState.lastCommandError)
        #expect(error.contains("GET /v1/things"))
        #expect(error.contains("X-Trace"), "the message has to name which header")
    }

    @Test("A path that could never match a request is refused")
    func unmatchablePathIsRefused() throws {
        let appState = try makeAppStateWithProject()

        // An endpoint whose path does not start with "/" cannot match any request the server will
        // ever receive: before the executor was in this path it imported, appeared in the list, and
        // was dead. `HARParser.extractPath` puts the slash back, but the Swagger 2 branch of
        // `OpenAPIParser` passes the document's path key through as written.
        appState.commitImportedCandidates([candidate(path: "v1/things")])

        #expect(appState.currentProject?.endpoints.isEmpty == true)
        let error = try #require(appState.lastCommandError)
        #expect(error.contains("Invalid path"))
    }

    @Test("A refused candidate does not take the rest of the import with it")
    func oneRefusalDoesNotLoseTheBatch() throws {
        let appState = try makeAppStateWithProject()

        // The shape of a real capture: a handful of good calls with dead ones mixed in. Refusing the
        // whole import over one of them would make the feature useless on genuine traffic.
        appState.commitImportedCandidates([
            candidate(path: "/v1/cancelled", statusCode: 0),
            candidate(),
            candidate(method: .post, path: "/v1/things", headers: ["X-Trace": "abc\r\nX-Evil: 1"]),
        ])

        let endpoints = try #require(appState.currentProject?.endpoints)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.path == "/v1/things")
        #expect(endpoints.first?.method == .get)

        let error = try #require(appState.lastCommandError)
        #expect(error.contains("Skipped 2 of 3"))
        #expect(error.contains("GET /v1/cancelled"))
        #expect(error.contains("POST /v1/things"))
    }
}
