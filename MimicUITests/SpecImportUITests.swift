import Foundation
import XCTest

// MARK: - Page object

/// The import sheet, for either kind.
///
/// One page object rather than two, because the sheet *is* one screen: `ImportWorkflowScreen` renders
/// both flows and only the identifiers, the title and the empty/error copy vary by
/// `ImportKind`. The two existing page objects — `HARImportPage` and `OpenAPIImportPage` in
/// `MimicUITests.swift` — reach the empty state and nothing past it, and they are left alone: the
/// tests that use them pass, and this suite needs the review screen, which neither describes.
///
/// **Three different targeting strategies live here, and which one a member uses is not arbitrary.**
///
/// - *Identifier over `.any` descendants* for everything in the review list's own body and footer —
///   `import.candidateList`, `import.importButton`, `import.duplicateWarning`, the
///   `import.candidate.index.<n>` row cells. `ImportWorkflowScreen`'s root pairs its identifier with
///   `.accessibilityElement(children: .contain)` and its own note says nothing between it and these
///   leaves masks them, so their names reach the tree.
/// - *Content* for anything inside a `DSPanelHeader` or a `DSEmptyState`. Both flatten their leaves:
///   dumped from `app.debugDescription`, a `DSEmptyState`'s heading arrives as
///   `identifier: 'ds.empty.sidebar.endpoints', value: No endpoints` — the container's name, not the
///   heading's own. See mimic-ui-tests, `references/accessibility-tree.md`, rule 8. So the review
///   header, the selection count, the sheet title and the parse-error copy are matched by the words
///   they show. That is not a weaker assertion here: nothing else in the window says "Endpoints
///   found" or "3 of 4 selected", so the query is still specific to the thing under test.
/// - *Identifier **or** label, in one predicate* for the buttons in the panel header, whose
///   identifiers may or may not survive that same flattening. One predicate rather than a
///   `.exists`-branching accessor, deliberately: a branching accessor resolves once, and every
///   `isEnabled` poll in this file depends on the returned element re-running its query.
@MainActor
struct ImportSheetPage {
    let app: XCUIApplication
    /// `harImportView` or `openAPIImportView` — `ImportKind.rootAccessibilityIdentifier`.
    let rootIdentifier: String
    /// `harImport` or `openAPIImport` — the prefix the empty/parsing/error states are named with.
    let statePrefix: String
    /// The heading the sheet opens with, which is also the only thing on screen naming the kind.
    let sheetTitle: String

    static func har(_ app: XCUIApplication) -> ImportSheetPage {
        ImportSheetPage(
            app: app,
            rootIdentifier: "harImportView",
            statePrefix: "harImport",
            sheetTitle: "Import from HAR"
        )
    }

    static func openAPI(_ app: XCUIApplication) -> ImportSheetPage {
        ImportSheetPage(
            app: app,
            rootIdentifier: "openAPIImportView",
            statePrefix: "openAPIImport",
            sheetTitle: "Import from OpenAPI"
        )
    }

    // MARK: Primitives

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A static text showing exactly `text`, wherever it is in the tree.
    ///
    /// Label *and* value, because which of the two a `StaticText` carries its words in depends on how
    /// SwiftUI realized it — the rule this suite learned from `DSEmptyState`, whose text arrives as
    /// the value.
    func staticText(reading text: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", text, text)
        ).firstMatch
    }

    /// A static text containing `text`. Scoped to `staticTexts` rather than `.any`: a `CONTAINS`
    /// predicate over every descendant in the window times out inside XCUITest's own query
    /// evaluation, which `MimicUITests` has already been bitten by once.
    func staticText(containing text: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
    }

    // MARK: Chrome

    var root: XCUIElement { element(identifier: rootIdentifier) }

    /// The sheet's own 20pt heading — "Import from HAR" / "Import from OpenAPI".
    var title: XCUIElement { staticText(reading: sheetTitle) }

    var cancelButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR identifier == %@ OR label == %@",
                "\(statePrefix).cancelButton", "ds.button.\(rootIdentifier).cancel", "Cancel"
            )
        ).firstMatch
    }

    // MARK: Review screen

    var candidateList: XCUIElement { element(identifier: "import.candidateList") }

    /// The review panel's header title.
    var reviewHeader: XCUIElement { staticText(reading: "Endpoints found") }

    /// The header's "n of m selected" count, as an assertion on the exact words.
    func selectionCount(_ text: String) -> XCUIElement { staticText(reading: text) }

    var selectAllButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR identifier == %@ OR label == %@ OR label == %@",
                "import.selectAll", "ds.button.import.selectAll", "Select all endpoints", "Select all"
            )
        ).firstMatch
    }

    var deselectAllButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR identifier == %@ OR label == %@ OR label == %@",
                "import.deselectAll", "ds.button.import.deselectAll",
                "Deselect all endpoints", "Deselect all"
            )
        ).firstMatch
    }

    /// The commit button.
    ///
    /// Its visible title tracks the selection ("Import 3 endpoints") but its accessibility label does
    /// not — `ImportReviewList` sets `.accessibilityLabel("Import selected endpoints")` over it — so
    /// the count is matched on nowhere in this file. See the note in `SpecImportUITests` about
    /// IMPREV-13.
    var importButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR identifier == %@ OR label == %@",
                "import.importButton", "ds.button.import.commit", "Import selected endpoints"
            )
        ).firstMatch
    }

    // MARK: Rows

    /// A row's path cell, which is also the row's index-addressable handle.
    ///
    /// Index, never UUID. Every other identifier on a candidate row is suffixed with an id the parser
    /// minted this run, so a test cannot name a row before reading one out of the tree; `rowIndex` is
    /// the position the table presents. Clicking this cell exercises the row's own tap gesture —
    /// `ImportCandidateRow` puts `.onTapGesture` on the whole line with a `.contentShape`, and the
    /// `Text` inside consumes nothing.
    func candidatePath(at index: Int) -> XCUIElement {
        element(identifier: "import.candidate.index.\(index)")
    }

    /// `operation`, `name`, `status` or `size` on the row at `index`.
    func candidateCell(_ field: String, at index: Int) -> XCUIElement {
        element(identifier: "import.candidate.index.\(index).\(field)")
    }

    /// `duplicate`, `binaryBody` or `bodyDropped`. The branches are mutually exclusive, so *which*
    /// identifier is present is the assertion.
    ///
    /// Strictly by identifier, with no fall back to the flag's accessibility label: a label-matched
    /// fallback would find another row's flag and turn every "row n carries no flag" check into a
    /// test that cannot fail.
    func candidateFlag(_ kind: String, at index: Int) -> XCUIElement {
        element(identifier: "import.candidate.index.\(index).flag.\(kind)")
    }

    /// A row's checkbox, by the label `ImportCandidateRow` gives it: "Import GET /api/orders".
    ///
    /// By label, because the toggle's own `import.toggle.<uuid>` is both UUID-suffixed and inside the
    /// row's `.contain` group. Only usable where the fixture makes the method-and-path pair unique.
    func toggle(labelled label: String) -> XCUIElement {
        app.checkBoxes.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    // MARK: Footer

    var duplicateNote: XCUIElement { element(identifier: "import.duplicateWarning") }
    var bodySizeWarning: XCUIElement { element(identifier: "import.bodySizeWarning") }
    var binaryBodyWarning: XCUIElement { element(identifier: "import.binaryBodyWarning") }

    // MARK: Parse error

    var errorHeading: XCUIElement { staticText(reading: "Parse error") }

    func errorMessage(containing text: String) -> XCUIElement { staticText(containing: text) }

    var chooseAnotherFileButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                "ds.button.empty.\(statePrefix).error.cta", "Choose another file"
            )
        ).firstMatch
    }

    // MARK: Waits

    /// Waits for the review screen to be on show.
    ///
    /// Three candidates polled together, never `a.waitForExistence(t) || b.waitForExistence(t)` —
    /// that form waits out the first element's entire timeout before it looks at the second. Three
    /// rather than one because they fail independently: `import.candidateList` is a container
    /// identifier, `import.candidate.index.0` is a row cell's, and "Endpoints found" is content. A
    /// suite in which every test's first wait depends on one identifier landing is a suite that
    /// reports one broken identifier as a broken feature.
    @discardableResult
    func waitForReviewList(timeout: TimeInterval) -> Bool {
        UITestApp.waitForAny([candidateList, candidatePath(at: 0), reviewHeader], timeout: timeout)
    }

    /// Waits for the sheet to be gone — by its root identifier *and* by a string only it shows, so a
    /// root identifier that never landed cannot make this pass vacuously in one direction while the
    /// sheet is still up.
    @discardableResult
    func waitForDismissal(showing visibleText: String, timeout: TimeInterval = 10) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            !root.exists && !staticText(reading: visibleText).exists
        }
    }
}

// MARK: - Fixtures

/// Every byte the importer is pointed at in this suite, written out as a literal.
///
/// Deliberately *not* borrowed from `Tests/SpecImportTests` or built by calling anything in
/// `SpecImport`: a fixture derived from the mechanism under test moves with it, and these files exist
/// to prove the real `HARParser` and `OpenAPIParser` produce particular rows. The expected row
/// contents are written out beside each one so the arithmetic — a body's byte count, a suggested
/// name, a duplicate — is pinned rather than recomputed.
enum SpecImportFixtures {

    /// Four entries, three of them distinct: the fourth repeats entry 0's method and path, so it
    /// arrives flagged `Duplicate` and deselected.
    ///
    /// Expected rows, in order:
    ///
    /// | # | method | path             | name           | status | size |
    /// |---|--------|------------------|----------------|--------|------|
    /// | 0 | GET    | /api/orders      | Get Orders     | 200    | 13 B |
    /// | 1 | POST   | /api/orders      | Create Orders  | 201    | 9 B  |
    /// | 2 | GET    | /api/customers   | Get Customers  | 200    | 16 B |
    /// | 3 | GET    | /api/orders      | Get Orders     | 200    | 14 B | ← duplicate
    ///
    /// The sizes are the UTF-8 lengths of the bodies below, and the names are what
    /// `ImportCandidateBuilder.suggestName` makes of the paths once `api` is dropped as a common
    /// prefix. Three of four selected.
    static let reviewHAR = """
    {
      "log": {
        "version": "1.2",
        "creator": { "name": "Mimic UI tests", "version": "1.0" },
        "entries": [
          {
            "request": { "method": "GET", "url": "https://api.example.com/api/orders" },
            "response": {
              "status": 200,
              "content": { "mimeType": "application/json", "text": "{\\"orders\\":[]}" }
            }
          },
          {
            "request": { "method": "POST", "url": "https://api.example.com/api/orders" },
            "response": {
              "status": 201,
              "content": { "mimeType": "application/json", "text": "{\\"id\\":42}" }
            }
          },
          {
            "request": { "method": "GET", "url": "https://api.example.com/api/customers" },
            "response": {
              "status": 200,
              "content": { "mimeType": "application/json", "text": "{\\"customers\\":[]}" }
            }
          },
          {
            "request": { "method": "GET", "url": "https://api.example.com/api/orders" },
            "response": {
              "status": 200,
              "content": { "mimeType": "application/json", "text": "{\\"orders\\":[7]}" }
            }
          }
        ]
      }
    }
    """

    /// One row per warning flag, plus a clean row, so each flag's presence *and* absence is checked
    /// against the same list.
    ///
    /// - Row 0 is base64 whose decoded bytes (`FF D8 FF E0`, a JPEG's opening) are not valid UTF-8,
    ///   which is what `bodyIsBinary` means; 4 bytes, so it is nowhere near the size limit and can
    ///   only be flagged for the binary reason.
    /// - Row 1 carries a body one byte over the 1 MB limit — `bodyDropped`, size "1.0 MB".
    /// - Row 2 is an ordinary small JSON body and must carry no flag at all.
    ///
    /// Nothing here repeats a route, so the duplicate note must be absent too.
    static func flagsHAR(oversizedBody: String) -> String {
        """
        {
          "log": {
            "version": "1.2",
            "entries": [
              {
                "request": { "method": "GET", "url": "https://api.example.com/api/photos/thumbnail" },
                "response": {
                  "status": 200,
                  "content": {
                    "mimeType": "image/jpeg",
                    "encoding": "base64",
                    "text": "/9j/4A=="
                  }
                }
              },
              {
                "request": { "method": "GET", "url": "https://api.example.com/api/reports/full" },
                "response": {
                  "status": 200,
                  "content": { "mimeType": "application/json", "text": "\(oversizedBody)" }
                }
              },
              {
                "request": { "method": "GET", "url": "https://api.example.com/api/health" },
                "response": {
                  "status": 200,
                  "content": { "mimeType": "application/json", "text": "{\\"ok\\":true}" }
                }
              }
            ]
          }
        }
        """
    }

    /// The body a `bodyDropped` row needs: one byte past `ImportCandidateBuilder.bodySizeLimit`.
    ///
    /// The number is written out rather than read from `SpecImport` — this target links no such
    /// module, and a fixture that asked the mechanism what "too large" means would move with it.
    /// 1_048_577 bytes renders as "1.0 MB" through `ImportCandidate.bodySizeLabel`.
    static let oversizedBodyByteCount = 1_048_577

    /// Two GraphQL calls down one route. They share `POST /graphql`, so without the operation name
    /// the second would be a duplicate of the first and the review would be two identical rows.
    ///
    /// Expected rows: index 0 operation `GetCart`, index 1 operation `AddItem`, neither flagged.
    static let graphQLHAR = """
    {
      "log": {
        "version": "1.2",
        "entries": [
          {
            "request": {
              "method": "POST",
              "url": "https://api.example.com/graphql",
              "postData": {
                "mimeType": "application/json",
                "text": "{\\"operationName\\":\\"GetCart\\",\\"query\\":\\"query GetCart { cart { id } }\\"}"
              }
            },
            "response": {
              "status": 200,
              "content": { "mimeType": "application/json", "text": "{\\"data\\":{}}" }
            }
          },
          {
            "request": {
              "method": "POST",
              "url": "https://api.example.com/graphql",
              "postData": {
                "mimeType": "application/json",
                "text": "{\\"operationName\\":\\"AddItem\\",\\"query\\":\\"mutation AddItem { addItem { id } }\\"}"
              }
            },
            "response": {
              "status": 200,
              "content": { "mimeType": "application/json", "text": "{\\"data\\":{}}" }
            }
          }
        ]
      }
    }
    """

    /// One committable entry and one a browser writes for a cancelled request: `"status": 0`.
    ///
    /// `EndpointValidator.validateStatusCode` accepts 200...599, so the second is refused by
    /// `ImportCommitter` and reported through `lastCommandError` — the one path that puts the
    /// "Couldn't apply that change" alert over an import.
    static let refusedHAR = """
    {
      "log": {
        "version": "1.2",
        "entries": [
          {
            "request": { "method": "GET", "url": "https://api.example.com/api/good" },
            "response": {
              "status": 200,
              "content": { "mimeType": "application/json", "text": "{\\"ok\\":true}" }
            }
          },
          {
            "request": { "method": "GET", "url": "https://api.example.com/api/cancelled" },
            "response": { "status": 0 }
          }
        ]
      }
    }
    """

    /// Truncated JSON: the decoder fails on the bytes themselves, which is the common shape of the
    /// error state — a file saved half-written, or one that was never a HAR.
    static let malformedHAR = """
    {
      "log": {
        "entries": [
          { "request": { "method": "GET",
    """

    /// An OpenAPI 3 document with three operations across two paths, under a `servers` prefix.
    ///
    /// Expected rows, in the order `OpenAPIParser` sorts paths:
    ///
    /// | # | method | path                 | name            | status |
    /// |---|--------|----------------------|-----------------|--------|
    /// | 0 | GET    | /v2/orders           | List Orders     | 200    |
    /// | 1 | POST   | /v2/orders           | Create an order | 201    |
    /// | 2 | GET    | /v2/orders/:orderId  | Get one order   | 200    |
    ///
    /// Three things are pinned by that table and each has been wrong at some point: the `servers`
    /// prefix reaching the route (`/v2/…`), `{orderId}` being rewritten to Mimic's `:orderId`, and
    /// `summary` beating `operationId` when both could name a row.
    static let openAPISpec = """
    {
      "openapi": "3.0.3",
      "info": { "title": "Mimic UI test API", "version": "1.0.0" },
      "servers": [ { "url": "https://api.example.com/v2" } ],
      "paths": {
        "/orders": {
          "get": {
            "operationId": "listOrders",
            "responses": {
              "200": {
                "description": "Every order",
                "content": {
                  "application/json": { "example": { "orders": [] } }
                }
              }
            }
          },
          "post": {
            "operationId": "createOrder",
            "summary": "Create an order",
            "responses": { "201": { "description": "Created" } }
          }
        },
        "/orders/{orderId}": {
          "get": {
            "operationId": "getOrder",
            "summary": "Get one order",
            "responses": { "200": { "description": "One order" } }
          }
        }
      }
    }
    """

    /// Valid JSON, not a spec. `OpenAPI.Document` requires `openapi`, `info` and `paths`, so this
    /// reaches the same error arm a YAML file does — which is the arm whose guidance names YAML.
    static let notASpec = """
    {
      "name": "definitely not an OpenAPI document",
      "endpoints": ["/orders", "/customers"]
    }
    """
}

// MARK: - Tests

/// Spec import, end to end: the review screen, its flags, both parsers, and the commit that turns
/// candidates into endpoints.
///
/// **Why this suite needs a launch hook when nothing else does.** Spec import is the one workflow
/// with no `ControlCommand` behind it — `ControlPlane` and `MimicCLICore` do not depend on
/// `SpecImport` in either manifest — so a script cannot set it up, and its only entry point is an
/// `NSOpenPanel`, which is out-of-process for a sandboxed app and undriveable from XCUITest. Without
/// a seam the review screen is unreachable, and XCUITest is the only automated coverage it can ever
/// have. `MIMIC_IMPORT_FILE` bypasses **the panel and nothing else**: `WorkspaceView`
/// `.presentInjectedImportIfNeeded()` hands the URL to `ImportWorkflow.parseFile`, which is the same
/// method `chooseFile` calls once a panel has returned one, so the real parser reads the real bytes
/// and the real `AppState.commitImportedCandidates` publishes the result. Injecting candidates
/// instead would be a fixture built from the mechanism under test, and it would stay green with both
/// parsers deleted.
///
/// **Two steps this suite deliberately does not claim.**
///
/// - *IMPREV-13*, the commit button's label tracking the selection. `ImportReviewList` builds the
///   title "Import 3 endpoints" and then sets `.accessibilityLabel("Import selected endpoints")` on
///   the same button, which replaces it — the count is not in the tree at all. Asserting on it needs
///   a production change (an `.accessibilityValue` carrying the count, or the count in the label),
///   not a cleverer query.
/// - *IMPERR-03/-04*, actually clicking "Choose another file". The click runs
///   `NSOpenPanel.runModal()`, which for a sandboxed app is a modal window in another process that
///   this suite can neither see nor dismiss; the app would sit in a modal loop for the rest of the
///   run. The affordance's presence and enabled state are asserted instead, and the click is left
///   uncovered rather than faked.
final class SpecImportUITests: MimicUITestCase {

    // MARK: - The launch hook

    /// The file the import flow should open instead of running its panel.
    ///
    /// Spelled here because this target links no `AppFeatures`; the one declaration is
    /// `UITestSupport.importFileEnvironmentKey`. Same reasoning as
    /// `UITestApp.controlFileEnvironmentKey`.
    private static let importFileEnvironmentKey = "MIMIC_IMPORT_FILE"

    /// `har` or `openapi` — `UITestSupport.importKindEnvironmentKey`. A missing or unrecognised value
    /// means no injection at all, rather than a guess from the file extension.
    private static let importKindEnvironmentKey = "MIMIC_IMPORT_KIND"

    /// Where the *app* is told to look, and it has to be tilde-relative.
    ///
    /// Mimic ships with `app-sandbox` and `files.user-selected.read-write` and nothing else, so the
    /// only absolute paths it may read are ones a user picked in a panel — and a UI test cannot drive
    /// a panel, which is the entire reason this hook exists. `/tmp/fixture.har` is therefore *denied*,
    /// not missing, and the failure surfaces as a parse error about a file the tester can see with
    /// their own eyes. A path beginning `~/` is expanded by the sandboxed app into its own container,
    /// where it reads without an entitlement. Same reasoning `UITestSupport.databaseURL` records for
    /// the run's store and `UITestApp.controlFileOverridePath` records for the discovery file.
    private static let appVisibleDirectory = "~/Library/Application Support/devxa.Mimic"

    /// Where the *runner* writes, which is the same directory seen from outside the sandbox.
    ///
    /// The runner is unsandboxed — `MimicUITests` sets `ENABLE_HARDENED_RUNTIME: NO` and carries no
    /// entitlements file — so `homeDirectoryForCurrentUser` is the real home and the app's container
    /// has to be spelled out. The two halves of this pair must stay in step: whatever the app expands
    /// `~/Library/Application Support/devxa.Mimic` into is exactly this path.
    private static var runnerVisibleDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("devxa.Mimic", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("devxa.Mimic", isDirectory: true)
    }

    /// The fixture's file name for this test, carrying the runner's pid so a file left behind by a
    /// crashed run can never describe this one — the guard `UITestApp.controlFileOverridePath` uses.
    private var fixtureFileName: String?
    /// What `configureLaunchEnvironment` exports. Set *before* `launchApp()`, always.
    private var injectedImportPath: String?
    private var injectedImportKind: String?
    /// The file as the runner can see it, so teardown can remove it.
    private var fixtureURL: URL?

    /// Exports the two keys. Called once, before `launch()` — the environment binds at process spawn
    /// and a key set from a test body reaches nothing.
    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        // Port 0 lets the OS pick the control plane's port, the way every suite added since the base
        // class does: a run then collides neither with a developer's running instance nor with a
        // second run on the same machine. The discovery-file half of that isolation is exported by
        // the launch contract itself.
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
        if let injectedImportPath {
            app.launchEnvironment[Self.importFileEnvironmentKey] = injectedImportPath
        }
        if let injectedImportKind {
            app.launchEnvironment[Self.importKindEnvironmentKey] = injectedImportKind
        }
    }

    override func tearDownWithError() throws {
        if let fixtureURL {
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        fixtureURL = nil
        fixtureFileName = nil
        injectedImportPath = nil
        injectedImportKind = nil
        try super.tearDownWithError()
    }

    // MARK: - Driving a run

    /// Launches with an injected import and drives the app to the workspace, where the sheet opens.
    ///
    /// The order matters twice over. The environment is decided *before* `launchApp()`, because the
    /// process reads it once at spawn. The bytes are written *after* it, because the destination is
    /// the app's sandbox container: letting the app create the container itself keeps this suite out
    /// of the business of hand-building one, and nothing reads the file until `WorkspaceView`
    /// appears — which is after the project below is created.
    @MainActor
    private func launchWithInjectedImport(
        fixtureNamed name: String,
        kind: String,
        contents: String,
        projectName: String
    ) throws {
        let unique = "mimic-uitests-import-\(ProcessInfo.processInfo.processIdentifier)-\(name)"
        fixtureFileName = unique
        injectedImportPath = "\(Self.appVisibleDirectory)/\(unique)"
        injectedImportKind = kind

        launchApp()

        let directory = Self.runnerVisibleDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(unique)
        try Data(contents.utf8).write(to: url, options: .atomic)
        fixtureURL = url

        createProjectViaUI(name: projectName)
    }

    // MARK: - Assertions

    /// A parse is a file read plus a decode on a detached task, behind a project creation and a sheet
    /// presentation. Generous, and paid only when something is wrong.
    private static let parseTimeout: TimeInterval = 30

    @MainActor
    private func assertExists(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if element.waitForExistence(timeout: timeout) { return }
        XCTFail("\(what) should exist.\n\(element.debugDescription)", file: file, line: line)
    }

    /// One-shot on purpose. Every use here follows a wait for the state the element belongs to, and a
    /// wait-for-absence would hide an element that appears and then goes away.
    @MainActor
    private func assertAbsent(
        _ element: XCUIElement,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.exists else { return }
        XCTFail("\(what) should not exist — \(describe(element))", file: file, line: line)
    }

    @MainActor
    private func assertReads(
        _ element: XCUIElement,
        _ expected: String,
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matched = UITestApp.waitUntil(timeout: timeout) {
            guard element.exists else { return false }
            if element.label == expected { return true }
            let value = element.value.map { String(describing: $0) } ?? ""
            return value == expected
        }
        if matched { return }
        XCTFail("\(what) should read \"\(expected)\" — \(describe(element))", file: file, line: line)
    }

    @MainActor
    private func assertEnabled(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let enabled = UITestApp.waitUntil(timeout: timeout) { element.exists && element.isEnabled }
        if enabled { return }
        XCTFail("\(what) should be enabled — \(describe(element))", file: file, line: line)
    }

    @MainActor
    private func assertDisabled(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let disabled = UITestApp.waitUntil(timeout: timeout) { element.exists && !element.isEnabled }
        if disabled { return }
        XCTFail("\(what) should be disabled — \(describe(element))", file: file, line: line)
    }

    @MainActor
    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "the element does not exist" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "saw label \"\(element.label)\", value \"\(value)\", enabled \(element.isEnabled)"
    }

    // MARK: - The sidebar, as the commit's witness

    /// One entry per endpoint row in the sidebar.
    ///
    /// Distinct identifiers rather than raw element count: `EndpointSidebarRow` pairs
    /// `endpoint-<uuid>` with `.accessibilityElement(children: .contain)`, and whether that surfaces
    /// as one element or several is a SwiftUI detail that has already changed once for the request
    /// log's rows. Counting names is the version that stays correct either way.
    @MainActor
    private func endpointRowIdentifiers() -> Set<String> {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "endpoint-"))
        var identifiers: Set<String> = []
        for index in 0..<rows.count {
            identifiers.insert(rows.element(boundBy: index).identifier)
        }
        return identifiers
    }

    /// Exactly `count`, never "at least": committing one candidate too many — the pre-deselected
    /// duplicate, say — has to fail this.
    @MainActor
    private func assertEndpointRowCount(
        _ count: Int,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settled = UITestApp.waitUntil(timeout: timeout) { endpointRowIdentifiers().count == count }
        if settled { return }
        XCTFail(
            "The sidebar should hold \(count) endpoints — saw \(endpointRowIdentifiers().count)",
            file: file,
            line: line
        )
    }

    /// A sidebar row showing `text`, matched on content because `EndpointSidebarRow`'s own cells are
    /// unnamed. Only used once the import sheet is gone, so nothing else in the window is showing the
    /// same path.
    @MainActor
    private func sidebarText(_ text: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", text, text)
        ).firstMatch
    }

    // MARK: - IMPREV: the review screen

    /// Every row the parser produced, with the four facts the reviewer decides on.
    ///
    /// Covers IMPHAR-03, IMPHAR-10, IMPREV-01, IMPREV-03, IMPREV-05, IMPREV-15, IMPREV-16.
    @MainActor
    func testHARReviewListsEveryParsedCandidate() throws {
        try launchWithInjectedImport(
            fixtureNamed: "review.har",
            kind: "har",
            contents: SpecImportFixtures.reviewHAR,
            projectName: "HAR review"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The HAR should parse and the review screen should appear"
        )

        // IMPHAR-03 / IMPREV-01 — the sheet says which importer it is, and the panel beneath it says
        // what it found.
        assertExists(sheet.title, "The sheet heading \"Import from HAR\"")
        assertExists(sheet.reviewHeader, "The review panel's \"Endpoints found\" header")
        assertExists(sheet.candidateList, "The candidate list")

        // IMPREV-03 — a row's method, path, name, status and size. The method badge is the one cell
        // with no index-addressable identifier (it is named `ds.method.<uuid>`); the other four are
        // pinned here, and the toggle asserted further down carries the method in its label.
        assertReads(sheet.candidatePath(at: 0), "/api/orders", "Row 0's path")
        assertReads(sheet.candidateCell("name", at: 0), "Get Orders", "Row 0's suggested name")
        assertReads(sheet.candidateCell("status", at: 0), "200", "Row 0's status")
        assertReads(sheet.candidateCell("size", at: 0), "13 B", "Row 0's body size")

        assertReads(sheet.candidatePath(at: 1), "/api/orders", "Row 1's path")
        assertReads(sheet.candidateCell("name", at: 1), "Create Orders", "Row 1's suggested name")
        assertReads(sheet.candidateCell("status", at: 1), "201", "Row 1's status")
        assertReads(sheet.candidateCell("size", at: 1), "9 B", "Row 1's body size")

        assertReads(sheet.candidatePath(at: 2), "/api/customers", "Row 2's path")
        assertReads(sheet.candidateCell("name", at: 2), "Get Customers", "Row 2's suggested name")
        assertReads(sheet.candidateCell("size", at: 2), "16 B", "Row 2's body size")

        // IMPHAR-10 — four entries in, four rows out, and no fifth.
        assertReads(sheet.candidatePath(at: 3), "/api/orders", "Row 3's path")
        assertAbsent(sheet.candidatePath(at: 4), "A fifth candidate row")

        // IMPREV-15 — the repeat is flagged, and only the repeat.
        assertExists(sheet.candidateFlag("duplicate", at: 3), "The Duplicate flag on row 3")
        assertAbsent(sheet.candidateFlag("duplicate", at: 0), "A Duplicate flag on row 0")
        assertAbsent(sheet.candidateFlag("duplicate", at: 1), "A Duplicate flag on row 1")
        assertAbsent(sheet.candidateFlag("duplicate", at: 2), "A Duplicate flag on row 2")

        // IMPREV-05, and the other half of IMPREV-15: four found, three selected, so exactly one row
        // arrived pre-deselected. Which one is settled by the click in
        // `testReviewSelectionControlsDriveTheSelection`.
        assertExists(sheet.selectionCount("3 of 4 selected"), "The \"3 of 4 selected\" count")

        // IMPREV-16 — and neither of the two warnings this capture does not earn.
        assertExists(sheet.duplicateNote, "The \"Duplicates are deselected by default\" note")
        assertAbsent(sheet.bodySizeWarning, "The body-size footer warning")
        assertAbsent(sheet.binaryBodyWarning, "The binary-body footer warning")
    }

    /// Select all, deselect all, one checkbox, one row click — each read back off the count.
    ///
    /// The count is the assertion rather than a checkbox's `value` because it is the thing the screen
    /// actually promises, and because a checkbox reports its state as an `NSNumber`, a `String` or
    /// nothing at all depending on how AppKit realized it — a reading that can be absent is a
    /// reading that can make this pass while nothing is selected.
    ///
    /// Covers IMPREV-05, IMPREV-06, IMPREV-07, IMPREV-09, IMPREV-10, IMPREV-11, IMPREV-12, IMPREV-14.
    @MainActor
    func testReviewSelectionControlsDriveTheSelection() throws {
        try launchWithInjectedImport(
            fixtureNamed: "review.har",
            kind: "har",
            contents: SpecImportFixtures.reviewHAR,
            projectName: "HAR selection"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )
        assertExists(sheet.selectionCount("3 of 4 selected"), "The initial selection count")

        // IMPREV-09 — select all takes the deselected duplicate with it.
        assertEnabled(sheet.selectAllButton, "Select all, while a candidate is deselected")
        sheet.selectAllButton.click()
        assertExists(sheet.selectionCount("4 of 4 selected"), "The count after Select all")
        // IMPREV-10
        assertDisabled(sheet.selectAllButton, "Select all, once every candidate is selected")
        assertEnabled(sheet.deselectAllButton, "Deselect all, while everything is selected")

        // IMPREV-11
        sheet.deselectAllButton.click()
        assertExists(sheet.selectionCount("0 of 4 selected"), "The count after Deselect all")
        // IMPREV-12 and IMPREV-14 — a control that cannot change anything says so.
        assertDisabled(sheet.deselectAllButton, "Deselect all, with nothing selected")
        assertDisabled(sheet.importButton, "The commit button, with nothing selected")
        assertEnabled(sheet.selectAllButton, "Select all, with nothing selected")

        // IMPREV-06 — one checkbox, addressed by the label `ImportCandidateRow` composes for it.
        // `/api/customers` is the one route this capture visits exactly once, so the label is unique.
        let customers = sheet.toggle(labelled: "Import GET /api/customers")
        assertExists(customers, "The checkbox for GET /api/customers")
        customers.click()
        assertExists(sheet.selectionCount("1 of 4 selected"), "The count after ticking one checkbox")
        assertEnabled(sheet.importButton, "The commit button, with one candidate selected")

        // IMPREV-07 — the whole line is the target, not the 18pt checkbox at its leading edge. Row 3
        // is the duplicate, which also settles that row 3 was the one pre-deselected above.
        //
        // Two *different* rows rather than the same one twice, deliberately: two clicks on one
        // element inside the double-click interval are delivered as a double-click, and what a
        // SwiftUI `.onTapGesture` does with that is not something to build an assertion on. Row 3
        // goes off→on and row 2 — the customers row ticked just above — goes on→off, so both
        // directions are still covered.
        sheet.candidatePath(at: 3).click()
        assertExists(sheet.selectionCount("2 of 4 selected"), "The count after clicking row 3")
        sheet.candidatePath(at: 2).click()
        assertExists(sheet.selectionCount("1 of 4 selected"), "The count after clicking row 2")
    }

    /// The commit, and the endpoints it is supposed to leave behind.
    ///
    /// Covers IMPHAR-10 through to the end of the flow, IMPREV-23 and IMPREV-25.
    @MainActor
    func testCommittingTheReviewCreatesTheEndpoints() throws {
        try launchWithInjectedImport(
            fixtureNamed: "review.har",
            kind: "har",
            contents: SpecImportFixtures.reviewHAR,
            projectName: "HAR commit"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )
        assertExists(sheet.selectionCount("3 of 4 selected"), "The selection count before committing")
        // Nothing has been imported yet, so the sidebar is still empty.
        assertEndpointRowCount(0, timeout: 3)

        // IMPREV-23
        assertEnabled(sheet.importButton, "The commit button")
        sheet.importButton.click()

        // IMPREV-25 — the sheet goes, and the three selected candidates arrive as endpoints. Three,
        // not four: the duplicate was deselected and must not have been committed.
        XCTAssertTrue(
            sheet.waitForDismissal(showing: "Endpoints found"),
            "The import sheet should dismiss once the import is confirmed"
        )
        assertEndpointRowCount(3)
        assertExists(sidebarText("/api/customers"), "The imported /api/customers row in the sidebar")
        assertExists(sidebarText("Get Orders"), "The imported endpoint named Get Orders")
        assertExists(sidebarText("Create Orders"), "The imported endpoint named Create Orders")
    }

    /// Return commits, because the review screen's commit is its default action.
    ///
    /// Covers IMPREV-24 and, again from the keyboard, IMPREV-25.
    @MainActor
    func testReturnKeyCommitsTheReview() throws {
        try launchWithInjectedImport(
            fixtureNamed: "review.har",
            kind: "har",
            contents: SpecImportFixtures.reviewHAR,
            projectName: "HAR return"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )
        assertExists(sheet.selectionCount("3 of 4 selected"), "The selection count before committing")

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            sheet.waitForDismissal(showing: "Endpoints found"),
            "Return should fire the review screen's default action and dismiss the sheet"
        )
        assertEndpointRowCount(3)
        assertExists(sidebarText("/api/customers"), "The imported /api/customers row in the sidebar")
    }

    // MARK: - IMPREV: the three warning flags

    /// One row per flag, and a clean row proving the column is not simply always populated.
    ///
    /// Covers IMPREV-17, IMPREV-18, IMPREV-19, IMPREV-20.
    @MainActor
    func testBinaryAndOversizedBodiesAreFlagged() throws {
        let oversized = String(
            repeating: "x",
            count: SpecImportFixtures.oversizedBodyByteCount
        )
        try launchWithInjectedImport(
            fixtureNamed: "flags.har",
            kind: "har",
            contents: SpecImportFixtures.flagsHAR(oversizedBody: oversized),
            projectName: "HAR flags"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )
        assertExists(sheet.selectionCount("3 of 3 selected"), "The selection count")

        // IMPREV-19 — a binary body is flagged for being binary, not for its size: these four bytes
        // are nowhere near the limit, so this flag can only have come from the binary branch.
        assertReads(sheet.candidatePath(at: 0), "/api/photos/thumbnail", "Row 0's path")
        assertExists(sheet.candidateFlag("binaryBody", at: 0), "The Binary body flag on row 0")
        assertReads(sheet.candidateCell("size", at: 0), "4 B", "Row 0's body size")

        // IMPREV-17 — one byte over the limit is over the limit. The warning ink the size is drawn in
        // is not readable from the accessibility tree; `ImportReviewRowContrastTests` measures that.
        assertReads(sheet.candidatePath(at: 1), "/api/reports/full", "Row 1's path")
        assertExists(sheet.candidateFlag("bodyDropped", at: 1), "The Body dropped flag on row 1")
        assertReads(sheet.candidateCell("size", at: 1), "1.0 MB", "Row 1's body size")

        // The clean row. Without this the two checks above would also pass against a column that
        // flagged everything.
        assertReads(sheet.candidatePath(at: 2), "/api/health", "Row 2's path")
        assertAbsent(sheet.candidateFlag("binaryBody", at: 2), "A Binary body flag on row 2")
        assertAbsent(sheet.candidateFlag("bodyDropped", at: 2), "A Body dropped flag on row 2")
        assertAbsent(sheet.candidateFlag("duplicate", at: 2), "A Duplicate flag on row 2")

        // IMPREV-18 and IMPREV-20 — the footer says both things once, for the whole list.
        assertExists(sheet.bodySizeWarning, "The \"exceed the 1 MB body limit\" footer warning")
        assertExists(sheet.binaryBodyWarning, "The \"binary bodies\" footer warning")
        // Nothing here repeats a route, so the third footer note must be absent.
        assertAbsent(sheet.duplicateNote, "The duplicates footer note")
    }

    /// GraphQL: one route, two operations, two rows that can be told apart.
    ///
    /// Covers IMPREV-04.
    @MainActor
    func testGraphQLCandidatesShowTheirOperationNames() throws {
        try launchWithInjectedImport(
            fixtureNamed: "graphql.har",
            kind: "har",
            contents: SpecImportFixtures.graphQLHAR,
            projectName: "HAR GraphQL"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )

        assertReads(sheet.candidatePath(at: 0), "/graphql", "Row 0's path")
        assertReads(sheet.candidatePath(at: 1), "/graphql", "Row 1's path")
        assertReads(sheet.candidateCell("operation", at: 0), "GetCart", "Row 0's GraphQL operation")
        assertReads(sheet.candidateCell("operation", at: 1), "AddItem", "Row 1's GraphQL operation")

        // The operation is also what keeps the second row from being read as a repeat of the first:
        // they share `POST /graphql` and differ by nothing else.
        assertAbsent(sheet.candidateFlag("duplicate", at: 1), "A Duplicate flag on row 1")
        assertExists(sheet.selectionCount("2 of 2 selected"), "The selection count")
    }

    /// A candidate the executor refuses is reported, not silently dropped.
    ///
    /// Covers IMPREV-26.
    @MainActor
    func testRefusedCandidateIsReportedAndTheRestStillLand() throws {
        try launchWithInjectedImport(
            fixtureNamed: "refused.har",
            kind: "har",
            contents: SpecImportFixtures.refusedHAR,
            projectName: "HAR refusal"
        )

        let sheet = ImportSheetPage.har(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )
        // A browser writes `"status": 0` for a cancelled request; both rows arrive selected, because
        // nothing in the *review* screen knows the executor will refuse one.
        assertReads(sheet.candidateCell("status", at: 1), "0", "Row 1's status")
        assertExists(sheet.selectionCount("2 of 2 selected"), "The selection count")

        sheet.importButton.click()
        XCTAssertTrue(
            sheet.waitForDismissal(showing: "Endpoints found"),
            "The import sheet should dismiss on commit even when a candidate is refused"
        )

        let refusal = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "GET /api/cancelled", "GET /api/cancelled"
            )
        ).firstMatch
        assertExists(refusal, "The refusal naming the skipped route", timeout: 15)

        let okButton = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "commandError.okButton")
        ).firstMatch
        assertExists(okButton, "The \"Couldn't apply that change\" alert's OK button")
        okButton.click()

        // The good candidate still landed: a refusal rolls back its own candidate, not the import.
        assertEndpointRowCount(1)
        assertExists(sidebarText("/api/good"), "The imported /api/good row in the sidebar")
    }

    // MARK: - IMPAPI: the OpenAPI flow

    /// Every operation in the document, under the prefix its `servers` entry declares, through to the
    /// endpoints it creates.
    ///
    /// Covers IMPAPI-03, IMPAPI-09, IMPREV-01, IMPREV-23, IMPREV-25.
    @MainActor
    func testOpenAPISpecListsEveryOperationAndCommits() throws {
        try launchWithInjectedImport(
            fixtureNamed: "spec.json",
            kind: "openapi",
            contents: SpecImportFixtures.openAPISpec,
            projectName: "Spec import"
        )

        let sheet = ImportSheetPage.openAPI(app)
        XCTAssertTrue(
            sheet.waitForReviewList(timeout: Self.parseTimeout),
            "The file should parse and the review screen should appear"
        )

        // IMPAPI-03 / IMPREV-01
        assertExists(sheet.title, "The sheet heading \"Import from OpenAPI\"")
        assertExists(sheet.reviewHeader, "The review panel's \"Endpoints found\" header")

        // IMPAPI-09 — three operations across two paths, in the order the parser sorts them, each
        // carrying the document's `/v2` prefix and, for the last, Mimic's wildcard syntax.
        assertReads(sheet.candidatePath(at: 0), "/v2/orders", "Row 0's path")
        assertReads(sheet.candidateCell("name", at: 0), "List Orders", "Row 0's suggested name")
        assertReads(sheet.candidateCell("status", at: 0), "200", "Row 0's status")

        assertReads(sheet.candidatePath(at: 1), "/v2/orders", "Row 1's path")
        assertReads(sheet.candidateCell("name", at: 1), "Create an order", "Row 1's suggested name")
        assertReads(sheet.candidateCell("status", at: 1), "201", "Row 1's status")

        assertReads(sheet.candidatePath(at: 2), "/v2/orders/:orderId", "Row 2's path")
        assertReads(sheet.candidateCell("name", at: 2), "Get one order", "Row 2's suggested name")

        assertAbsent(sheet.candidatePath(at: 3), "A fourth candidate row")
        assertExists(sheet.selectionCount("3 of 3 selected"), "The selection count")

        // IMPREV-23 / IMPREV-25, from the other importer.
        sheet.importButton.click()
        XCTAssertTrue(
            sheet.waitForDismissal(showing: "Endpoints found"),
            "The OpenAPI import sheet should dismiss once the import is confirmed"
        )
        assertEndpointRowCount(3)
        assertExists(sidebarText("/v2/orders/:orderId"), "The imported wildcard route in the sidebar")
        assertExists(sidebarText("Get one order"), "The imported endpoint named Get one order")
    }

    // MARK: - IMPERR: the parse error

    /// A file the HAR parser cannot read, and what the sheet does about it.
    ///
    /// Covers IMPERR-01, IMPERR-02, IMPERR-07 and IMP-03. The retry button's *click* is deliberately
    /// not performed — see the note on this class.
    @MainActor
    func testMalformedHARShowsParseErrorAndOffersRetry() throws {
        try launchWithInjectedImport(
            fixtureNamed: "broken.har",
            kind: "har",
            contents: SpecImportFixtures.malformedHAR,
            projectName: "HAR error"
        )

        let sheet = ImportSheetPage.har(app)

        // IMPERR-01 — the error state, not the empty state and not a review list.
        assertExists(sheet.errorHeading, "The \"Parse error\" heading", timeout: Self.parseTimeout)
        assertAbsent(sheet.candidateList, "The candidate list")
        assertAbsent(sheet.reviewHeader, "The review panel header")

        // IMPERR-02 — the guidance `ImportWorkflow.readableParseError` appends. Without it the sheet
        // shows Foundation's "isn't in the correct format" and nothing a reader can act on.
        assertExists(
            sheet.errorMessage(containing: "Mimic reads HAR 1.2"),
            "The HAR format guidance appended to the decode error"
        )

        // IMPERR-03's affordance. The click would run `NSOpenPanel.runModal()`, which is out of
        // process for a sandboxed app and would leave the app in a modal loop this suite cannot end.
        assertExists(sheet.chooseAnotherFileButton, "The \"Choose another file\" retry button")
        assertEnabled(sheet.chooseAnotherFileButton, "The \"Choose another file\" retry button")

        // IMPERR-07 / IMP-03 — abandoning from the error state, with Cancel rather than Escape, which
        // is the half `MimicUITests` does not cover.
        sheet.cancelButton.click()
        XCTAssertTrue(
            sheet.waitForDismissal(showing: "Parse error"),
            "Cancel should dismiss the import sheet from the error state"
        )
        XCTAssertTrue(
            workspace.assertVisible(timeout: 10),
            "The workspace should be usable again after the import is abandoned"
        )
    }

    /// The same arm on the other importer, whose guidance names the other format.
    ///
    /// Two tests rather than one parameterised over the kind: the *point* is that the two messages
    /// differ, and a single test asserting "the right one of the two appeared" would pass with both
    /// wired to the same string.
    ///
    /// Covers IMPERR-01 and IMPERR-02 for the OpenAPI flow.
    @MainActor
    func testUnrecognisedSpecShowsTheOpenAPIFormatGuidance() throws {
        try launchWithInjectedImport(
            fixtureNamed: "notaspec.json",
            kind: "openapi",
            contents: SpecImportFixtures.notASpec,
            projectName: "Spec error"
        )

        let sheet = ImportSheetPage.openAPI(app)

        assertExists(sheet.errorHeading, "The \"Parse error\" heading", timeout: Self.parseTimeout)
        assertAbsent(sheet.candidateList, "The candidate list")
        // Content, not an identifier, so this cannot pass merely because the identifier above never
        // landed: no review screen means no "Endpoints found".
        assertAbsent(sheet.reviewHeader, "The review panel header")

        // The YAML sentence is the one that matters: a spec written in YAML is the common way to
        // reach this state, and the raw decode error names neither the cause nor the remedy.
        assertExists(
            sheet.errorMessage(containing: "YAML has to be converted first"),
            "The OpenAPI format guidance appended to the decode error"
        )
        assertAbsent(
            sheet.errorMessage(containing: "Mimic reads HAR 1.2"),
            "The HAR importer's guidance on the OpenAPI sheet"
        )

        assertExists(sheet.chooseAnotherFileButton, "The \"Choose another file\" retry button")
    }
}
