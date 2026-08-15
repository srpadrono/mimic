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

    /// Whatever the error state is currently saying, for a diagnostic rather than an assertion.
    ///
    /// Both identifiers, because `DSEmptyState` may flatten: the message reaches the tree under its
    /// own `ds.empty.<prefix>.error.message`, or — if the container's name is stamped over its
    /// descendants — under `ds.empty.<prefix>.error`, the same handle the container itself wears.
    /// Label *and* value for the reason ``staticText(reading:)`` gives. `nil` when there is no error
    /// state up, which is itself the answer to "did the parse fail".
    ///
    /// **Every element wearing either handle, and the *texts* first — not `firstMatch` over `.any`.**
    /// That was this property's shape for one CI round and it read back the single word
    /// "Parse error" while the error state was up: `.any` is answered in tree order, so the first
    /// match is whichever of the container or the heading the tree lists first, and neither of those
    /// carries the sentence. The read report `WorkspaceView.presentInjectedImportIfNeeded()` appends
    /// is in the *message*, so `assertFixtureWasReadable(_:)` could never see it and both error-state
    /// tests failed saying the fixture had not been read — of a fixture the app had plainly read and
    /// failed to parse, which is exactly what those two tests are for.
    ///
    /// So: `staticTexts` (the sentence is a `Text` under either realization), every match rather than
    /// the first, joined. The container is the fallback for the shape where the message is folded
    /// into it and no static text wears the name at all.
    var parseErrorText: String? {
        let byIdentifier = NSPredicate(
            format: "identifier == %@ OR identifier == %@",
            "ds.empty.\(statePrefix).error.message", "ds.empty.\(statePrefix).error"
        )

        var sawErrorState = false
        var parts: [String] = []

        let texts = app.staticTexts.matching(byIdentifier)
        // Guarded on `firstMatch` because `count` on a query with no matches raises rather than
        // answering zero — the rule `ErrorAlertUITests.jsonWarningText()` was corrected by.
        if texts.firstMatch.exists {
            sawErrorState = true
            for match in texts.allElementsBoundByIndex {
                let text = shownText(of: match)
                if !text.isEmpty, !parts.contains(text) { parts.append(text) }
            }
        }

        if parts.isEmpty {
            let container = app.descendants(matching: .any).matching(byIdentifier).firstMatch
            if container.exists {
                sawErrorState = true
                let text = shownText(of: container)
                if !text.isEmpty { parts.append(text) }
            }
        }

        guard sawErrorState else { return nil }
        return parts.joined(separator: " | ")
    }

    /// An element's words, wherever it keeps them. Value first — `DSEmptyState`'s text arrives there
    /// under some realizations and in the label under others.
    private func shownText(of element: XCUIElement) -> String {
        let value = element.value.map { String(describing: $0) } ?? ""
        return value.isEmpty ? element.label : value
    }

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

/// A fixture: the resource the app parses, and the literal this file says that resource holds.
///
/// Both halves, because the bytes now live in two places and only one of them is this file. The app
/// reads `App/Resources/UITestFixtures/<resourceName>` out of its own bundle — see
/// `UITestSupport.importFileEnvironmentKey` for why nothing is handed across the filesystem any
/// more — while ``SpecImportFixtures`` keeps the literal that resource is supposed to hold, next to
/// the table of rows it is supposed to produce. ``SpecImportUITests/assertBundledFixtureMatchesLiteral(_:)``
/// compares them on every launch, so a resource edited without its table goes red here rather than
/// somewhere confusing three assertions later.
struct SpecImportFixture {
    /// The file name under `App/Resources/UITestFixtures/`, which is also the whole of what the app
    /// is told: `MIMIC_IMPORT_FILE` carries a resource name, never a path.
    let resourceName: String
    /// What that resource holds, as a literal this file owns.
    let bytes: String
}

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

    /// What stands in for that megabyte inside the bundled resource, expanded by the app when
    /// `MIMIC_IMPORT_PADDING` names a count — `UITestSupport.importPaddingToken`, spelled here
    /// because this target links no `AppFeatures`.
    ///
    /// A megabyte of `x` is not a thing to commit to a repository, and it is emphatically not a
    /// thing to ship inside an app bundle. The count still comes from this file, as a literal, so
    /// the fixture remains the suite's: expanding a token by a number the *test* chose is not the
    /// same as asking `SpecImport` what "too large" means.
    static let paddingToken = "MIMIC_UITEST_BODY_PADDING"

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

    // MARK: The bundled resources

    /// Each literal above, paired with the resource that has to hold it.
    ///
    /// Every name ends in `.json` whatever the file holds — a HAR *is* JSON, a truncated HAR is not
    /// but the extension is not a claim about that. Two reasons, both deliberate: `.json` is a type
    /// Xcode copies into `Contents/Resources` from a buildable folder without anyone having to say
    /// so, and the importer is chosen by `MIMIC_IMPORT_KIND` rather than by extension, so an
    /// extension nobody can take as a hint is the safer one to write.

    static let review = SpecImportFixture(
        resourceName: "mimic-uitest-review.json",
        bytes: reviewHAR
    )

    /// The one fixture whose bundled bytes are not the parsed bytes: the app expands
    /// ``paddingToken`` to ``oversizedBodyByteCount`` bytes as it reads. The literal here is the
    /// *file*, token and all, which is what the drift check compares against.
    static let flags = SpecImportFixture(
        resourceName: "mimic-uitest-flags.json",
        bytes: flagsHAR(oversizedBody: paddingToken)
    )

    static let graphQL = SpecImportFixture(
        resourceName: "mimic-uitest-graphql.json",
        bytes: graphQLHAR
    )

    static let refused = SpecImportFixture(
        resourceName: "mimic-uitest-refused.json",
        bytes: refusedHAR
    )

    static let malformed = SpecImportFixture(
        resourceName: "mimic-uitest-broken.json",
        bytes: malformedHAR
    )

    static let openAPI = SpecImportFixture(
        resourceName: "mimic-uitest-openapi.json",
        bytes: openAPISpec
    )

    static let notASpecDocument = SpecImportFixture(
        resourceName: "mimic-uitest-notaspec.json",
        bytes: notASpec
    )
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
/// One fixture's bytes are not quite the file's: the app expands `SpecImportFixtures.paddingToken`
/// to a count this file names, because the body that has to exceed the importer's 1 MB limit is a
/// megabyte of `x` and that does not belong in a repository or in a shipped bundle. The count is a
/// literal here, not a number read from `SpecImport`, so the fixture is still the suite's.
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
///
/// **What two red CI rounds taught, because the shape of it will recur.**
///
/// *Round one.* All eight tests that need the review screen failed on the same line, and the two
/// that need only *a* parse error passed. The split was the diagnosis: the sheet was presenting, so
/// `.task`, `UITestSupport.importInjection()` and the `#if DEBUG` presentation were all working —
/// the parse was failing, on every fixture, including five structurally valid ones that `HARModels`'
/// almost-entirely-optional decoder cannot reject. That leaves the file read, and the two passes
/// were `ImportWorkflow.readableParseError` appending its format guidance to a "no such file"
/// exactly as it does to a decode failure. The runner spelled out a container path and the app
/// expanded a `~`: two answers to "where is home" that a sandbox is free to disagree about.
///
/// *Round two* replaced the guess with an observation. The runner wrote the fixture into whichever
/// directory held `mimic-uitests.sqlite`, the store the app had just opened, so neither side had to
/// assert where a container lives. **The probe found no store in either candidate directory** — and
/// the app was plainly running against a working store, because it created projects and saved them.
/// Whatever denies the runner that look (a container it is not permitted to read is the likeliest;
/// the same runner cannot `bind(2)` either), the conclusion is the same and it is not about paths:
/// *these two processes cannot rendezvous on the filesystem at all.*
///
/// So round three stops trying. The fixtures are **resources in the app's own bundle**, listed in
/// ``SpecImportFixtures`` and shipped from `App/Resources/UITestFixtures/`; `MIMIC_IMPORT_FILE`
/// carries a resource name and the app resolves it through `Bundle.main`. Nothing is written, no
/// directory is probed, no tilde is expanded, and the sandbox has no opinion about an app reading
/// its own bundle. Two things guard the cost of that move:
///
/// - ``assertBundledFixtureMatchesLiteral(_:)`` compares the shipped resource against the literal in
///   this file whenever the runner can read the built app, so the suite still owns the bytes its row
///   tables describe.
/// - ``assertFixtureWasReadable(_:)`` takes the app's own word for it. `WorkspaceView`
///   `.presentInjectedImportIfNeeded()` appends "*N* bytes read" or "unreadable: …" to the sheet's
///   error text, and the two error-state tests require the former before they will believe a parse
///   error is about the bytes.
///
/// **Diagnostics go in the assertion message, never to stdout.** Round two printed a full dump of
/// both sides on every failure and *not one line of it reached the xcodebuild log* — the app's
/// stdout is not the runner's, and the runner's is not the log's. `importDiagnostics` is folded into
/// the `XCTFail` message instead, which the log does carry.
final class SpecImportUITests: MimicUITestCase {

    // MARK: - The launch hook

    /// The resource the import flow should open instead of running its panel: a name inside the
    /// app's **own bundle**, never a path.
    ///
    /// Spelled here because this target links no `AppFeatures`; the one declaration is
    /// `UITestSupport.importFileEnvironmentKey`, which is also where the bundle contract and the two
    /// rounds of filesystem failure behind it are written down. Same reasoning as
    /// `UITestApp.controlFileEnvironmentKey`.
    private static let importFileEnvironmentKey = "MIMIC_IMPORT_FILE"

    /// `har` or `openapi` — `UITestSupport.importKindEnvironmentKey`. A missing or unrecognised value
    /// means no injection at all, rather than a guess from the file extension. Every fixture is
    /// named `.json`, so there is no extension to guess from either.
    private static let importKindEnvironmentKey = "MIMIC_IMPORT_KIND"

    /// How many bytes of `x` the app substitutes for `SpecImportFixtures.paddingToken` while it reads
    /// — `UITestSupport.importPaddingEnvironmentKey`. Only the flags fixture sets it.
    private static let importPaddingEnvironmentKey = "MIMIC_IMPORT_PADDING"

    /// What `configureLaunchEnvironment` exports. Set *before* `launchApp()`, always: the environment
    /// binds at process spawn, and a key set from a test body reaches nothing.
    private var injectedFixture: SpecImportFixture?
    private var injectedImportKind: String?
    private var injectedPaddingByteCount: Int?

    /// Exports the three keys. Called once, before `launch()`.
    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        // Port 0 lets the OS pick the control plane's port, the way every suite added since the base
        // class does: a run then collides neither with a developer's running instance nor with a
        // second run on the same machine. The discovery-file half of that isolation is exported by
        // the launch contract itself.
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
        if let injectedFixture {
            app.launchEnvironment[Self.importFileEnvironmentKey] = injectedFixture.resourceName
        }
        if let injectedImportKind {
            app.launchEnvironment[Self.importKindEnvironmentKey] = injectedImportKind
        }
        if let injectedPaddingByteCount {
            app.launchEnvironment[Self.importPaddingEnvironmentKey] = String(injectedPaddingByteCount)
        }
    }

    override func tearDownWithError() throws {
        // Nothing to delete any more: this suite writes no files at all. That is the whole point of
        // the bundle route, and the absence of a cleanup path is worth noticing rather than filling.
        injectedFixture = nil
        injectedImportKind = nil
        injectedPaddingByteCount = nil
        try super.tearDownWithError()
    }

    // MARK: - Driving a run

    /// Launches with an injected import and drives the app to the workspace, where the sheet opens.
    ///
    /// The order matters twice, and it used to matter three times.
    ///
    /// The environment is decided *before* `launchApp()`, because the process reads it once at spawn.
    /// What it carries is a resource name, which is known then and needs nothing to exist anywhere:
    /// the bytes shipped inside the app. The step this helper used to have between the launch and the
    /// project — probe for the app's Application Support, write the fixture into it — is gone, and
    /// the round-two note on this class is why it is not coming back.
    ///
    /// The project is created last, because `WorkspaceView` is the only view carrying
    /// `.presentInjectedImportIfNeeded()` and it does not exist until a project is open
    /// (`ContentView` branches on `currentProject`). Nothing reads the fixture before then.
    @MainActor
    private func launchWithInjectedImport(
        fixture: SpecImportFixture,
        kind: String,
        projectName: String,
        paddingByteCount: Int? = nil
    ) {
        injectedFixture = fixture
        injectedImportKind = kind
        injectedPaddingByteCount = paddingByteCount

        launchApp()
        assertBundledFixtureMatchesLiteral(fixture)
        createProjectViaUI(name: projectName)
    }

    // MARK: - The shipped resource, against the literal beside the assertions

    /// `Contents/Resources` of the `Mimic.app` this run is driving, or `nil` when the runner cannot
    /// find it.
    ///
    /// Walked up from the test bundle rather than asked of LaunchServices. The runner and the app are
    /// built side by side into `Build/Products/<Configuration>/`, whereas
    /// `NSWorkspace.urlForApplication(withBundleIdentifier:)` answers with whichever copy is
    /// *registered* — on a developer's machine plausibly one in `/Applications` that this run is not
    /// driving, which would make the check below a report about the wrong bundle.
    ///
    /// Read-only, and nothing the app depends on: the app finds its own resources through
    /// `Bundle.main`. This is the runner looking over its shoulder, and the only thing it is allowed
    /// to conclude is "these bytes differ".
    private static var appResourcesDirectory: URL? {
        var directory = Bundle(for: SpecImportUITests.self).bundleURL
        for _ in 0..<6 {
            directory = directory.deletingLastPathComponent()
            let bundle = directory.appendingPathComponent("Mimic.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundle.path) {
                return bundle
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
            }
        }
        return nil
    }

    /// The fixture as it shipped, read out of the built app — `nil` when the runner cannot see it.
    ///
    /// Both spellings, for the reason `UITestSupport.importFixtureURL(for:)` tries both: whether a
    /// buildable folder's subdirectory survives into `Contents/Resources` as a folder, or is
    /// flattened into it, is a packaging detail neither side should have to be right about.
    private static func bundledFixtureBytes(named name: String) -> String? {
        guard let resources = appResourcesDirectory else { return nil }
        let candidates = [
            resources
                .appendingPathComponent("UITestFixtures", isDirectory: true)
                .appendingPathComponent(name),
            resources.appendingPathComponent(name),
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    /// Fails when the shipped resource is not the literal this file says it is.
    ///
    /// This is what keeps the bytes the suite's own now that they live in the app bundle. The row
    /// tables in ``SpecImportFixtures`` describe a particular document — a body's byte count, a
    /// suggested name, a duplicate — and a resource edited without them would otherwise surface as
    /// three confusing row failures rather than as the drift it is.
    ///
    /// **Silent when it cannot read the app, and that is a scope rather than a hedge.** A runner that
    /// cannot find `Mimic.app` has said nothing about the fixture: the app reads its own bundle
    /// either way, and failing here would be this suite re-inventing the cross-process filesystem
    /// dependency that the bundle route exists to remove. When it *can* read, a mismatch is red.
    ///
    /// Trailing whitespace is trimmed on both sides. A Swift multi-line literal carries no final
    /// newline and a file on disk usually does; that difference is not drift.
    @MainActor
    private func assertBundledFixtureMatchesLiteral(
        _ fixture: SpecImportFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let shipped = Self.bundledFixtureBytes(named: fixture.resourceName) else { return }
        XCTAssertEqual(
            shipped.trimmingCharacters(in: .whitespacesAndNewlines),
            fixture.bytes.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(fixture.resourceName) in the built app is not the literal SpecImportFixtures holds. "
                + "Whichever half moved, the expected rows in this file describe the other one.",
            file: file,
            line: line
        )
    }

    // MARK: - Assertions

    /// A parse is a file read plus a decode on a detached task, behind a project creation and a sheet
    /// presentation. Generous, and paid only when something is wrong.
    private static let parseTimeout: TimeInterval = 30

    /// The words `WorkspaceView.presentInjectedImportIfNeeded()` appends to the sheet's error text
    /// once it has re-read the injected fixture: "… — 1097 bytes read". The other spelling is
    /// "unreadable: …", which is the case ``assertFixtureWasReadable(_:)`` exists to catch.
    private static let readReportMarker = "bytes read"

    /// Waits for the review screen, and folds everything it can see into the failure message.
    ///
    /// Every test in this suite goes through here, because every test's first claim is the same one
    /// and it has now failed eighteen times over with nothing to read but its own message.
    ///
    /// **In the message, not on stdout.** The previous round printed a full dump of both sides on
    /// every failure and not one line of it reached the xcodebuild log — the app's stdout is not the
    /// runner's, and the runner's is not the log's. An `XCTAttachment` would land in a ~280 MB
    /// xcresult that needs a Mac and an Xcode to open, and the CI job's own comment records three
    /// consecutive red runs diagnosed from failing *test names* alone because nobody opened one. A
    /// `XCTFail` message is the one channel that has been observed to arrive.
    @MainActor
    private func assertReviewList(
        _ sheet: ImportSheetPage,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if sheet.waitForReviewList(timeout: Self.parseTimeout) { return }
        XCTFail("\(message)\n\(importDiagnostics(sheet))", file: file, line: line)
    }

    /// Both sides of the injection, in one string a log can carry.
    ///
    /// The runner's half says what it exported and whether the resource it named is in the built app
    /// at all; the app's half — carried out through the sheet's error text by
    /// `WorkspaceView.presentInjectedImportIfNeeded()` — says which file it opened, how many bytes it
    /// got, and what the parser made of them. "unreadable" against a path inside `Mimic.app` would
    /// mean the resource did not ship; a decode error against a byte count means the bytes shipped
    /// and are wrong; no error state at all with no candidate list means the sheet never opened, so
    /// the hook did not run.
    ///
    /// `app.debugDescription` is deliberately not here. It runs to thousands of lines, and this
    /// string has to survive a trip through `xcresulttool` into a job log to be worth anything.
    @MainActor
    private func importDiagnostics(_ sheet: ImportSheetPage) -> String {
        var lines = ["--- injected import diagnostics ---"]
        lines.append("exported name:     \(app.launchEnvironment[Self.importFileEnvironmentKey] ?? "<unset>")")
        lines.append("exported kind:     \(app.launchEnvironment[Self.importKindEnvironmentKey] ?? "<unset>")")
        lines.append("exported padding:  \(app.launchEnvironment[Self.importPaddingEnvironmentKey] ?? "<unset>")")
        lines.append("app resources:     \(Self.appResourcesDirectory?.path ?? "<not found from the runner>")")
        if let name = injectedFixture?.resourceName {
            let shipped = Self.bundledFixtureBytes(named: name).map { "\($0.utf8.count) bytes" }
            lines.append("shipped resource:  \(name) — \(shipped ?? "not readable from the runner")")
        }
        lines.append("sheet root (\(sheet.rootIdentifier)): \(sheet.root.exists)")
        lines.append("sheet title:       \(sheet.title.exists)")
        lines.append("parse error state: \(sheet.errorHeading.exists)")
        lines.append("candidate list:    \(sheet.candidateList.exists)")
        lines.append("review header:     \(sheet.reviewHeader.exists)")
        lines.append("parse error text:  \(sheet.parseErrorText ?? "<no error state on screen>")")
        return lines.joined(separator: "\n")
    }

    /// The error-state tests' negative control, and they turned out to need one badly.
    ///
    /// `ImportWorkflow.readableParseError` appends its format guidance to *any* error, so "Parse
    /// error" over "Mimic reads HAR 1.2" is also exactly what a file the app could not open
    /// produces. That is why `testMalformedHARShowsParseErrorAndOffersRetry` and
    /// `testUnrecognisedSpecShowsTheOpenAPIFormatGuidance` were the only two tests in this suite to
    /// pass on the run where the injected file was never read at all: they were green over the bug
    /// the other eight were failing on, and their passing was evidence about nothing.
    ///
    /// This is what makes them mean something. A parse error is only *about the bytes* if the bytes
    /// were reachable, and **the app is the only witness to that** — the runner cannot stat a file
    /// inside the app's bundle on the app's behalf, and the two rounds of trying to reach agreement
    /// about a path are what put this suite here in the first place. So the app says it out loud:
    /// `WorkspaceView.presentInjectedImportIfNeeded()` re-reads the injected fixture whenever a parse
    /// failed and appends "*N* bytes read" — or "unreadable: …" — to the error text the sheet shows.
    /// This waits for the former.
    ///
    /// A missing file cannot produce "bytes read", which is the whole property: the vacuous pass this
    /// control exists to prevent now needs the app to lie about a read it performed.
    ///
    /// If the suffix is ever *truncated* out of the accessibility value rather than absent, this
    /// fails too — and it prints the entire error text, so the next reader can see that is what
    /// happened rather than guessing at it.
    ///
    /// **Two handles on the same sentence, polled together.** The identifier route is the one that
    /// says *which* element carries the report, and it is the one that went wrong: for a round it
    /// resolved to the error state's heading and read "Parse error", so this failed over an app that
    /// had read the file and said so. The words are the second handle — a static text containing
    /// "bytes read" is the app's report wherever `DSEmptyState` put it, and only the app can produce
    /// it, so the control is exactly as strong either way. Both are asked on every poll rather than
    /// in turn, for the reason `UITestApp.waitForAny` exists.
    @MainActor
    private func assertFixtureWasReadable(
        _ sheet: ImportSheetPage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var reported: String?
        let confirmed = UITestApp.waitUntil(timeout: Self.parseTimeout) {
            reported = sheet.parseErrorText
            if reported?.contains(Self.readReportMarker) == true { return true }
            return sheet.errorMessage(containing: Self.readReportMarker).exists
        }
        if confirmed { return }
        XCTFail(
            "The app never reported reading the injected fixture, so a parse error here cannot be "
                + "told apart from a file it could not open. The sheet says: "
                + (reported ?? "<no error state on screen>")
                + "\n\(importDiagnostics(sheet))",
            file: file,
            line: line
        )
    }

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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.review,
            kind: "har",
            projectName: "HAR review"
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The HAR should parse and the review screen should appear")

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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.review,
            kind: "har",
            projectName: "HAR selection"
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")
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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.review,
            kind: "har",
            projectName: "HAR commit"
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")
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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.review,
            kind: "har",
            projectName: "HAR return"
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")
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
        // The megabyte is not in the resource — the app expands `SpecImportFixtures.paddingToken`
        // to exactly this many bytes as it reads. The count is still a literal this file owns, so
        // the fixture does not move when `ImportCandidateBuilder.bodySizeLimit` does.
        launchWithInjectedImport(
            fixture: SpecImportFixtures.flags,
            kind: "har",
            projectName: "HAR flags",
            paddingByteCount: SpecImportFixtures.oversizedBodyByteCount
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")
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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.graphQL,
            kind: "har",
            projectName: "HAR GraphQL"
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")

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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.refused,
            kind: "har",
            projectName: "HAR refusal"
        )

        let sheet = ImportSheetPage.har(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")
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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.openAPI,
            kind: "openapi",
            projectName: "Spec import"
        )

        let sheet = ImportSheetPage.openAPI(app)
        assertReviewList(sheet, "The file should parse and the review screen should appear")

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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.malformed,
            kind: "har",
            projectName: "HAR error"
        )

        let sheet = ImportSheetPage.har(app)

        // Before anything about the message: the app has to have *read* the file, or the error
        // state below is a missing resource rather than malformed bytes. See
        // `assertFixtureWasReadable`.
        assertFixtureWasReadable(sheet)

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
        launchWithInjectedImport(
            fixture: SpecImportFixtures.notASpecDocument,
            kind: "openapi",
            projectName: "Spec error"
        )

        let sheet = ImportSheetPage.openAPI(app)

        // The same negative control as the HAR error test, and for the same reason.
        assertFixtureWasReadable(sheet)

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
