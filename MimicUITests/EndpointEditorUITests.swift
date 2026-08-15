import AppKit
import Foundation
import XCTest

/// The endpoint editor, the sidebar and the inspector's scenario list — the editing surface the
/// original suite covered only at its edges.
///
/// `MimicUITests` proves an endpoint can be created, given a status code and deleted. Everything
/// between those — the response headers, the JSON body, the group tag, the two delays, the
/// validation notes, the scenario list's own sheet and menus, and the sidebar's filter, scopes,
/// groups and context menu — had no test at all. Several page-object properties existed for years
/// without a single caller (`addHeaderButton`, `prettyPrintButton`, `headerKeyField(at:)`,
/// `delayField`, `groupTagField`, the whole of `NewScenarioSheetPage`), which is what "declared but
/// never used" looks like when nobody checks.
///
/// **Targeting rules this file obeys, because the tree does not.** A leaf inside `DSTabStrip`,
/// `DSPanelHeader`, `DSSectionHeader` or `DSEmptyState` loses its own identifier to the container's
/// — `.accessibilityElement(children: .contain)` keeps the child as its own element with its own
/// *label and value*, which is not the same thing. So "Add header", "Pretty-print JSON" and "Add
/// scenario" are matched by **label**, and where two controls share a label (two "Add endpoint"
/// buttons; two "Add scenario" buttons once the sheet is up) the query names the identifier it must
/// *not* have, so the two stay distinguishable instead of collapsing into a `firstMatch` coin toss.
///
/// The first CI run of this file taught the same lesson in two more places, and both fixes are
/// generalizations rather than one-offs. A **row of elements sharing one identifier** — the
/// `DSTextField` validation row under a wrapper that lends its name to everything below it, the
/// `DSJSONEditor` warning whose glyph and sentence both wear `ds.jsoneditor.<id>.error` — is read by
/// *content*, never by `firstMatch`, which resolves to whichever of them the tree lists first (a
/// glyph, whose AppKit label is the one word "Warning"). And a **`List` section header** does not
/// keep the identifier its `HStack` was given the way `EndpointSidebarRow` keeps its own, because
/// the row declares an accessibility element and the header does not — so the sidebar's group
/// sections are found by identifier *or* by the header's text, polled together.
///
/// **What is deliberately not here.** `editor.noActiveScenario` (EPEDIT-02) is unreachable from the
/// window: creating an endpoint always mints a Default scenario, and the scenario list refuses to
/// delete the last one — so no sequence of clicks produces an endpoint with a nil
/// `activeScenarioID`. Reaching it needs a launch hook or a CLI-seeded store, and a test that
/// pretended otherwise would be green about nothing. The status colour dot (EPEDIT-08) is
/// `.accessibilityHidden(true)` on purpose; its colour mapping belongs to a `DSColors` unit test.
final class EndpointEditorUITests: MimicUITestCase {

    // MARK: - Shared element resolution

    /// The label+value of an element as one string, so a caller comparing two moments cannot be
    /// fooled by which of the two a `StaticText` happened to carry its text in — the lesson
    /// `DSEmptyState` taught this suite, where the text arrives as the *value*.
    ///
    /// Returns empty for an absent element, so "gone" cannot read as "unchanged".
    @MainActor
    private func shownText(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "\(element.label)|\(value)"
    }

    /// An element addressed only by identifier, whatever AppKit realized it as.
    ///
    /// `matching(identifier:)` rather than an `NSPredicate` over `descendants(matching: .any)`: a
    /// predicate is evaluated against every element in the window and has already timed this suite
    /// out once inside XCUITest's own query evaluation.
    @MainActor
    private func anyElement(identified identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The longest thing said by any element carrying `identifier`, ignoring text fields.
    ///
    /// **For the rows where several elements share one name**, which is most of the ones this suite
    /// asserts text about: a container's `.accessibilityIdentifier` propagates to its descendants, so
    /// a `DSTextField` wrapped in a caller's identifier lends that name to its label, its input *and*
    /// its validation row, and a `DSJSONEditor` warning lends it to a glyph and a sentence. A
    /// `firstMatch` over those picks whichever the tree lists first, which is how CI came to report a
    /// JSON warning reading `Warning|` — the label AppKit gives `exclamationmark.triangle.fill`.
    ///
    /// Longest rather than "the one that says what I expect": a query written around the expected
    /// sentence would make the caller's assertion a restatement of the query, green whatever the app
    /// says. Length separates a message from a glyph's one word and from a field's one-word label
    /// without knowing either. The text field is skipped by type because its value is what somebody
    /// typed, which can be longer than both and is not what any of these callers are asking about.
    @MainActor
    private func longestText(identified identifier: String) -> String {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        var longest = ""
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            guard element.elementType != .textField else { continue }
            let text = shownText(of: element)
            if text.count > longest.count { longest = text }
        }
        return longest
    }

    // MARK: - DSTextField validation messages

    /// What the new-endpoint sheet's path field is complaining about, or `""` when it is not.
    ///
    /// **Not `ds.textfield.newEndpoint.path.error`, which is what `NewEndpointSheetPage.pathError`
    /// asks for and why three suites failed on the same wall at once.** `DSTextField` does compose
    /// that name for its validation row — but `NewEndpointSheet` then stamps
    /// `.accessibilityIdentifier("newEndpoint.pathField")` on the whole field, and a container's
    /// identifier overrides its descendants'. That propagation is the *point* of the wrapper: it is
    /// what makes `app.textFields["newEndpoint.pathField"]` resolve the input at all, which is the
    /// exception `DSTextField`'s own note asks callers to preserve. Its cost is that the field's
    /// label, its input and its validation row all report the wrapper's name, and no
    /// `ds.textfield.…` name reaches the tree. `NewProjectSheet` wraps `newProject.port` in
    /// `serverPortField` exactly the same way, so the port message is reached the same way.
    ///
    /// The three are then told apart by what they carry rather than by their names — see
    /// ``longestText(identified:)``.
    @MainActor
    private func pathValidationMessage() -> String {
        longestText(identified: "newEndpoint.pathField")
    }

    // MARK: - Editor scrolling

    /// The editor's own scroll view, not whichever one the tree lists first.
    ///
    /// The workspace has several — the sidebar's list, the request log's table — and scrolling the
    /// wrong one moves nothing the caller cares about.
    @MainActor
    private var editorScrollView: XCUIElement {
        let editor = anyElement(identified: "endpointEditor")
        if editor.exists {
            let inner = editor.descendants(matching: .scrollView).firstMatch
            if inner.exists { return inner }
        }
        return app.scrollViews.firstMatch
    }

    /// Brings an editor control into view before it is clicked.
    ///
    /// The editor is four stacked cards — Response, Response headers, Response body, Settings — and
    /// the body editor alone is 240pt tall, so on a default-sized window the Settings card starts
    /// below the fold. An element scrolled out of a clip view still *exists* in the accessibility
    /// tree, so `waitForExistence` says yes and `click()` then lands on whatever is actually at that
    /// screen point. `isHittable` is the question that distinguishes the two.
    ///
    /// Both scroll directions are tried because `scroll(byDeltaX:deltaY:)`'s sign convention is a
    /// wheel gesture's, not a content offset's, and getting it backwards would silently scroll away
    /// from the target.
    @MainActor
    @discardableResult
    private func revealInEditor(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        if element.isHittable { return true }

        let scroller = editorScrollView
        guard scroller.exists else { return element.isHittable }

        for delta in [-90.0, -90.0, -90.0, -90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0] {
            scroller.scroll(byDeltaX: 0, deltaY: CGFloat(delta))
            if element.isHittable { return true }
        }
        return element.isHittable
    }

    /// Gives the editor the drawer's height back.
    ///
    /// Cheaper and far more reliable than scrolling: the request log occupies the bottom of the
    /// window and hiding it is one toolbar click, after which all four editor cards usually fit.
    /// `revealInEditor` stays as the backstop for a small screen.
    @MainActor
    private func hideRequestLogDrawer() {
        guard workspace.toggleDrawerButton.waitForExistence(timeout: 5) else { return }
        guard workspace.drawerEmptyHeading.exists else { return }
        workspace.toggleDrawerButton.click()
        _ = workspace.drawerEmptyHeading.waitForNonExistence(timeout: 3)
    }

    /// Where an element is and whether the pointer can get to it, for a failure message.
    @MainActor
    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "<not in the tree>" }
        return "[value \(shownText(of: element)) frame \(element.frame) hittable \(element.isHittable)]"
    }

    /// Types into one of the editor's fields and proves the text landed *in that field*.
    ///
    /// **Not `XCTAssertTrue(revealInEditor(field))`, which is how this suite spent a CI round.**
    /// `isHittable` is false for these wells even when the window types into them perfectly well:
    /// `WorkspaceShellUITests.testGroupCrumbJumpsToAnotherGroup` clicks
    /// `endpointEditor.groupTagField`, types a tag, and watches the jump bar grow the crumb — and it
    /// passed in the same CI run in which the two tests below failed on that identical field being
    /// "reachable". A gate a working control cannot pass is not measuring reachability.
    ///
    /// What that gate was written to catch is real, and this catches it directly. An element scrolled
    /// out of the clip view still answers `waitForExistence`, and `click()` on macOS lands on
    /// whatever is at the point rather than refusing — so the way to know the field was reached is to
    /// read it back. A click that went anywhere else fails here, naming what the field holds and
    /// where it is, instead of surfacing three assertions later as "the tag never committed".
    ///
    /// `revealInEditor` still runs first: scrolling a below-the-fold card into view is worth doing,
    /// it is just not worth *asserting*.
    @MainActor
    private func typeIntoEditorField(_ field: XCUIElement, _ text: String, _ what: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(what) should be in the editor")
        revealInEditor(field)

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)

        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 3) { (field.value as? String) == text },
            "\(what) should hold \"\(text)\" after it was typed there — the field reads "
                + "\(describe(field)). A click that lands outside the field is how this reads when "
                + "the Settings card is below the fold in a narrow window."
        )
    }

    // MARK: - Sidebar element resolution

    /// The sidebar's endpoint rows, one element per row.
    ///
    /// A row is `endpoint-<uuid>` and a test cannot know the uuid — the app mints it — so the prefix
    /// is the only handle, exactly as `RequestLogDrawerPage` reaches log rows by `requestLog-`. The
    /// row pairs its identifier with `.contain`, so several elements can report the same name; the
    /// dedupe by identifier is what turns that back into a row count.
    ///
    /// The method badge inside a row is `ds.method.<uuid>` — no `endpoint-` prefix — so it cannot
    /// inflate the count.
    @MainActor
    private func sidebarEndpointRows() -> [XCUIElement] {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "endpoint-"))
        var seen: Set<String> = []
        var rows: [XCUIElement] = []
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            guard seen.insert(element.identifier).inserted else { continue }
            rows.append(element)
        }
        return rows
    }

    @MainActor
    private func waitForSidebarRowCount(_ count: Int, timeout: TimeInterval = 8) -> Bool {
        UITestApp.waitUntil(timeout: timeout) { self.sidebarEndpointRows().count == count }
    }

    /// The empty state's own "Add endpoint", separated from the navigator strip's by the identifier
    /// each one *is* wearing rather than by list order.
    ///
    /// `WorkspacePage.addEndpointButton` is `app.buttons["Add endpoint"].firstMatch` and matches
    /// either, on purpose — for a helper that just wants the sheet open, either is a correct answer.
    /// It is the wrong query for a test whose subject is *which* button was pressed. `DSTabStrip`
    /// stamps `ds.tabstrip.navigator` over every descendant, so the strip's copy is the one that
    /// reports that name and the empty state's copy is the one that does not.
    @MainActor
    private var emptyStateAddEndpointButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "Add endpoint", "ds.tabstrip.navigator"
            )
        ).firstMatch
    }

    @MainActor
    private var navigatorAddEndpointButton: XCUIElement {
        let flattened = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier == %@",
                "Add endpoint", "ds.tabstrip.navigator"
            )
        ).firstMatch
        if flattened.exists { return flattened }
        // If SwiftUI ever stops flattening the strip, the button keeps its own name.
        return app.buttons["sidebar.addEndpointButton"].firstMatch
    }

    @MainActor
    private var addEndpointButtonCount: Int {
        app.buttons.matching(NSPredicate(format: "label == %@", "Add endpoint")).count
    }

    @MainActor
    private var sidebarFilterField: XCUIElement {
        // `ds.filterfield.sidebar.filter`, and the element *type* is what separates the field from
        // the scope menu beside it — both report the container's name, which is what
        // `DSFilterField`'s own doc says will happen.
        app.textFields["ds.filterfield.sidebar.filter"]
    }

    /// The filter's scope pill. A SwiftUI `Menu` realizes as a menu button or a pop-up button
    /// depending on placement, and `app.buttons[…]` matches neither, so all three are tried — by
    /// **label**, since the identifier is flattened onto the `DSFilterField` container.
    @MainActor
    private var sidebarFilterScopeMenu: XCUIElement {
        let byMenuButton = app.menuButtons["Filter scope"].firstMatch
        if byMenuButton.exists { return byMenuButton }
        let byPopUp = app.popUpButtons["Filter scope"].firstMatch
        if byPopUp.exists { return byPopUp }
        let byButton = app.buttons["Filter scope"].firstMatch
        if byButton.exists { return byButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Filter scope"))
            .firstMatch
    }

    @MainActor
    private var sidebarNoMatchesRow: XCUIElement {
        anyElement(identified: "sidebar.noMatches")
    }

    /// Whether the sidebar is showing its "nothing matched" row, and whether it says the right
    /// thing.
    ///
    /// The identifier is checked first and the rendered string second, because the message is the
    /// whole point: `noMatchesMessage` picks one of three sentences depending on whether the search
    /// text, the method scope or neither emptied the list, and asserting only that *a* row appeared
    /// would pass for the wrong one.
    @MainActor
    private func sidebarReportsNoMatches(saying needle: String) -> Bool {
        let byIdentifier = sidebarNoMatchesRow
        if byIdentifier.exists, shownText(of: byIdentifier).contains(needle) { return true }
        return app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)
        ).firstMatch.exists
    }

    /// The navigator column itself, as something to scope a query to.
    ///
    /// Addressed by identifier across element types rather than as `app.otherElements["sidebar"]`:
    /// `WorkspaceView` pairs the name with `.accessibilityElement(children: .contain)`, and a
    /// container declared that way can realize as a group or as an `AXUnknown`. `WorkspacePage`
    /// spells one of the two and has never had a caller, so nothing has ever confirmed which.
    @MainActor
    private var sidebarElement: XCUIElement { anyElement(identified: "sidebar") }

    @MainActor
    private func groupSectionHeader(named identifierSuffix: String) -> XCUIElement {
        anyElement(identified: "sidebar.group.\(identifierSuffix)")
    }

    /// A group header found by the text it shows, scoped to the sidebar.
    ///
    /// Scoped, because the same word is on screen twice while this is being asserted: the editor's
    /// group tag field holds it, and the jump bar grows a group crumb for it. An unscoped query
    /// would be answered by either and would say nothing about the sidebar.
    @MainActor
    private func groupSectionHeader(showing text: String) -> XCUIElement {
        sidebarElement.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
            .firstMatch
    }

    /// Waits for a sidebar group section, by identifier **or** by the header's own text.
    ///
    /// `SidebarView` sets `sidebar.group.<name>` on the header, and CI could not find it for a
    /// section the model must have had — the two endpoints were both in the sidebar and one of them
    /// carried the tag. A `List` section header is a bare `HStack` inside a `Section`: unlike
    /// `EndpointSidebarRow`, which declares `.accessibilityElement(children: .contain)` and keeps
    /// `endpoint-<uuid>` all the way into the tree, it declares nothing, so AppKit's outline header
    /// row is free to swallow the modifier. The text is the header's own `Text(section.name)`.
    ///
    /// Both are polled together rather than waited on in turn — rule 9 of `mimic-ui-tests`.
    @MainActor
    private func waitForGroupSection(
        named name: String,
        showing text: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        UITestApp.waitForAny(
            [groupSectionHeader(named: name), groupSectionHeader(showing: text)],
            timeout: timeout
        )
    }

    // There is no `toggleGroupSection` here any more, and its absence is the record of a gap.
    //
    // A sidebar section built with `Section(isExpanded:)` collapses through SwiftUI's own affordance,
    // which the app never declares and therefore cannot name. Two ways in were tried over a CI round
    // and neither moved the section: clicking the header row — the header is a caption, not the
    // control — and hovering the row to reach the "Hide"/"Show" button AppKit is documented to draw
    // in it, which `sidebarElement.buttons` did not find under either label. What is left is a
    // coordinate click at a guessed point, which is not a test of an affordance but a test of a
    // layout, so the collapse step is left uncovered instead. The note on
    // `testAGroupSectionKeepsItsEndpointListedWhileASiblingIsEdited()` carries the production fix.

    // MARK: - Editor element resolution

    /// The "No custom headers" row.
    ///
    /// Scoped to `staticTexts` rather than `.any`: the identifier sits on the `Text` itself — the
    /// glyph beside it is `.accessibilityHidden`, so there is exactly one element here worth naming
    /// — and a typed query keeps the predicate off the rest of the window.
    @MainActor
    private var headersEmptyNote: XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@ OR value == %@",
                "endpointEditor.headers.empty", "No custom headers", "No custom headers"
            )
        ).firstMatch
    }

    /// Matched by **label**. The identifier is set, and it is stamped over by
    /// `ds.sectionheader.editor.headers` — the same flattening that makes `sidebar.addEndpointButton`
    /// and `inspector.closeRequestDetailButton` unreachable.
    @MainActor
    private var addHeaderButton: XCUIElement { app.buttons["Add header"].firstMatch }

    /// Matched by **label**, for the same reason as `addHeaderButton` —
    /// `ds.sectionheader.editor.body` wins over `endpointEditor.prettyPrintButton`.
    @MainActor
    private var prettyPrintButton: XCUIElement { app.buttons["Pretty-print JSON"].firstMatch }

    @MainActor
    private func removeHeaderButton(at index: Int) -> XCUIElement {
        app.descendants(matching: .button)
            .matching(identifier: "endpointEditor.removeHeader.\(index)")
            .firstMatch
    }

    @MainActor
    private var statusCodeValidationNote: XCUIElement {
        anyElement(identified: "endpointEditor.statusCode.error")
    }

    @MainActor
    private var delayValidationNote: XCUIElement {
        anyElement(identified: "endpointEditor.delay.error")
    }

    @MainActor
    private var globalDelayValue: XCUIElement {
        anyElement(identified: "endpointEditor.globalDelay")
    }

    @MainActor
    private var globalDelayNote: XCUIElement {
        anyElement(identified: "endpointEditor.globalDelay.note")
    }

    /// The JSON body's text view.
    ///
    /// `DSJSONEditor` tags its `CodeEditor` `ds.jsoneditor.editor.body`, but `CodeEditor` is an
    /// `NSViewRepresentable` wrapping a scroll view around an `NSTextView`, so the name may land on
    /// the wrapper with the typed content one level down. Both shapes are handled, and the untagged
    /// text view is the last resort — the editor is the only text view in the workspace.
    @MainActor
    private func bodyTextView() -> XCUIElement {
        let container = anyElement(identified: "ds.jsoneditor.editor.body")
        if container.exists {
            let inner = container.descendants(matching: .textView).firstMatch
            if inner.exists { return inner }
            if container.elementType == .textView { return container }
        }
        return app.textViews.firstMatch
    }

    /// What the JSON editor's warning row is saying, or `""` while it is not showing one.
    ///
    /// `DSJSONEditor` puts `ds.jsoneditor.<id>.error` on the `HStack` and — unlike `DSTextField`'s
    /// validation row and `EndpointEditorView`'s own `validationNote`, which both compose themselves
    /// with `.accessibilityElement()` — never collapses it, so the glyph and the sentence arrive as
    /// two elements wearing the same name. The first of them is the glyph: CI read this row as
    /// `Warning|`, which is `exclamationmark.triangle.fill`'s label and no value at all.
    @MainActor
    private func bodyWarningText() -> String {
        longestText(identified: "ds.jsoneditor.editor.body.error")
    }

    @MainActor
    private func bodyText() -> String {
        let editor = bodyTextView()
        guard editor.exists else { return "" }
        let value = editor.value.map { String(describing: $0) } ?? ""
        return value.isEmpty ? editor.label : value
    }

    /// Puts `json` in the response body by pasting it.
    ///
    /// **Pasted, not typed, and that is the point.** `CodeEditor` is a source editor, and a source
    /// editor may complete a bracket as it is typed — a `{` that arrives as `{}` turns the valid
    /// JSON this test means to write into invalid JSON, and the failure would then be about the
    /// editor's token completion rather than about anything the test is for. A paste is inserted
    /// verbatim, and ⌘V is a real user action rather than a back door into the model: the app keeps
    /// the standard Edit menu (`MimicScene` replaces only `.newItem`), so the key equivalent reaches
    /// the text view's `paste:` the way a person's would.
    @MainActor
    private func setResponseBody(_ json: String, expecting fragment: String) {
        let editor = bodyTextView()
        XCTAssertTrue(editor.waitForExistence(timeout: 5),
                      "The response body editor should be present in the editor pane")
        revealInEditor(editor)

        editor.click()
        editor.typeKey("a", modifierFlags: .command)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(json, forType: .string)
        app.typeKey("v", modifierFlags: .command)

        let pasted = UITestApp.waitUntil(timeout: 5) { self.bodyText().contains(fragment) }
        let shown = bodyText()
        XCTAssertTrue(pasted, "The response body editor should hold the pasted text — it holds \(shown)")
    }

    // MARK: - Inspector element resolution

    /// The inspector header's "+".
    ///
    /// By **label** — `DSPanelHeader` stamps `ds.panelheader.inspector` over its accessory slot, so
    /// `inspector.addScenarioButton` never reaches the tree; `DSPanelHeaderButton` sets its
    /// `accessibilityLabel` from its `help`, which is "Add scenario". The identifier the query
    /// excludes is the new-scenario sheet's confirm button, which carries the *same* label: without
    /// that clause this resolves to whichever the tree lists first the moment the sheet is up.
    @MainActor
    private var addScenarioButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "Add scenario", "newScenario.createButton"
            )
        ).firstMatch
    }

    /// Whether a scenario row reports itself active.
    ///
    /// Read from the row's `accessibilityValue` ("active"/"inactive"), not from its label. The label
    /// only *gains* a clause when active, so it can say a row is active but never that it is not —
    /// which is exactly the half `testSwitchActiveScenarioViaClick` left uncovered.
    @MainActor
    private func scenarioValue(named name: String) -> String {
        let row = inspector.scenarioRow(named: name)
        guard row.exists else { return "" }
        return (row.value as? String) ?? ""
    }

    @MainActor
    private func waitForScenarioValue(_ expected: String, named name: String, timeout: TimeInterval = 5) -> Bool {
        UITestApp.waitUntil(timeout: timeout) { self.scenarioValue(named: name) == expected }
    }

    // MARK: - 1. Sidebar: the two "Add endpoint" buttons are two buttons

    /// SIDEBAR-03, SIDEBAR-04.
    ///
    /// Both were "partial" for one reason: the page object matches either. This pins each one and
    /// then asserts the empty state's copy *goes away* once the project has an endpoint, which is
    /// what makes the pinning meaningful rather than a restatement of the query.
    @MainActor
    func testEmptyStateAndNavigatorAddEndpointButtonsAreDistinct() throws {
        launchApp()
        createProjectViaUI(name: "Add Buttons")

        XCTAssertTrue(workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
                      "A fresh project should show the sidebar's empty state")
        XCTAssertEqual(addEndpointButtonCount, 2,
                       "An empty project offers 'Add endpoint' twice — in the empty state and in the navigator strip")

        XCTAssertTrue(emptyStateAddEndpointButton.waitForExistence(timeout: 3),
                      "The empty state's own call to action should exist")
        emptyStateAddEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5),
                      "The empty state's 'Add endpoint' should open the new-endpoint sheet")

        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("From Empty State")
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("/api/first")
        newEndpointSheet.createButton.click()

        XCTAssertTrue(endpointEditor.pathLabel.waitForExistence(timeout: 5),
                      "Creating from the empty state should open the endpoint in the editor")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { self.addEndpointButtonCount == 1 },
            "With an endpoint in the project only the navigator's 'Add endpoint' should remain"
        )

        // And the survivor is the strip's, which is the button SIDEBAR-04 is about.
        XCTAssertTrue(navigatorAddEndpointButton.waitForExistence(timeout: 3),
                      "The navigator strip should still offer 'Add endpoint'")
        navigatorAddEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5),
                      "The navigator's '+' should open the new-endpoint sheet")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - 2. New endpoint sheet: path validation and the disabled confirm

    /// EPCREATE-05, EPCREATE-06, EPCREATE-10.
    ///
    /// `NewEndpointSheetPage.pathError` has existed unused since the page object was written, and its
    /// own doc admits the identifier it originally carried never existed. Its replacement —
    /// `ds.textfield.newEndpoint.path.error` — does not reach the tree either, for the reason
    /// ``pathValidationMessage()`` records, which is what the first CI run of this test found. The
    /// page object is left alone here; correcting it belongs with the page objects.
    @MainActor
    func testNewEndpointSheetRejectsAPathWithoutALeadingSlash() throws {
        launchApp()
        createProjectViaUI(name: "Path Validation")

        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5),
                      "The new-endpoint sheet should appear")
        XCTAssertFalse(newEndpointSheet.createButton.isEnabled,
                       "'Add endpoint' should be disabled while the name is blank")

        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("List Users")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 3) { self.newEndpointSheet.createButton.isEnabled },
            "'Add endpoint' should enable once the name is filled and the path still defaults to '/'"
        )

        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("api/users")

        // Raised on every keystroke by `NewEndpointSheet`'s `.onChange(of: path)` — there is nothing
        // to submit and nothing to blur first — and read through `pathValidationMessage`, not
        // through `NewEndpointSheetPage.pathError`, which cannot match. See that property's note.
        let statesTheRule = UITestApp.waitUntil(timeout: 5) {
            self.pathValidationMessage().contains("must start with")
        }
        let pathMessage = pathValidationMessage()
        XCTAssertTrue(statesTheRule,
                      "A path with no leading slash should show an inline message saying what is "
                          + "wrong — the field reads \(pathMessage)")
        XCTAssertFalse(newEndpointSheet.createButton.isEnabled,
                       "'Add endpoint' should be disabled while the path is invalid")

        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("/api/users")
        let cleared = UITestApp.waitUntil(timeout: 3) {
            self.pathValidationMessage().contains("must start with") == false
        }
        let remainingMessage = pathValidationMessage()
        XCTAssertTrue(cleared,
                      "Fixing the path should clear the message — it still reads \(remainingMessage)")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 3) { self.newEndpointSheet.createButton.isEnabled },
            "'Add endpoint' should re-enable for a valid path"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(newEndpointSheet.nameField.waitForNonExistence(timeout: 3),
                      "Escape should dismiss the new-endpoint sheet")
        XCTAssertTrue(workspace.sidebarEmptyHeading.waitForExistence(timeout: 3),
                      "Dismissing the sheet should leave the project without endpoints")
    }

    // MARK: - 3. New endpoint sheet: Cancel and Return

    /// EPCREATE-08, EPCREATE-09.
    @MainActor
    func testNewEndpointSheetCancelsAndSubmitsOnReturn() throws {
        launchApp()
        createProjectViaUI(name: "Sheet Keys")

        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.cancelButton.waitForExistence(timeout: 5),
                      "The new-endpoint sheet should offer Cancel")
        newEndpointSheet.cancelButton.click()

        XCTAssertTrue(newEndpointSheet.nameField.waitForNonExistence(timeout: 3),
                      "Cancel should dismiss the sheet")
        XCTAssertTrue(workspace.sidebarEmptyHeading.waitForExistence(timeout: 3),
                      "Cancel should create nothing")

        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5))
        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("Return Endpoint")
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("/api/return")

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(endpointEditor.pathLabel.waitForExistence(timeout: 5),
                      "Return should submit the sheet and open the endpoint in the editor")
        XCTAssertTrue(waitForSidebarRowCount(1),
                      "Return should have created exactly one endpoint")
    }

    // MARK: - 4. New endpoint sheet: the method picker

    /// EPCREATE-03.
    ///
    /// The original helper took a `method:` and dropped it, so every endpoint the suite has ever
    /// created was a GET and nothing proved the picker does anything. `MimicUITestCase` honours the
    /// parameter now; this is the assertion that says so.
    @MainActor
    func testMethodPickerCreatesAPostEndpoint() throws {
        launchApp()
        createProjectViaUI(name: "Method Picker")
        createEndpointViaUI(name: "Create Order", path: "/api/orders", method: "POST")

        let badge = anyElement(identified: "ds.method.editor.method")
        XCTAssertTrue(badge.waitForExistence(timeout: 5),
                      "The editor header should show the endpoint's method badge")
        let isPost = UITestApp.waitUntil(timeout: 5) { self.shownText(of: badge).contains("POST") }
        let badgeText = shownText(of: badge)
        XCTAssertTrue(isPost,
                      "The picker's POST should reach the created endpoint — the badge reads \(badgeText)")
    }

    // MARK: - 5. Response headers: the empty state, adding, and the commit

    /// EPHDR-01, EPHDR-02, EPHDR-03, EPHDR-04.
    ///
    /// The commit is proved by a round trip through the store rather than by reading back the field
    /// that was just typed into: the header write is debounced, and a field still holding its own
    /// text says nothing about whether the scenario ever received it.
    @MainActor
    func testAddingAResponseHeaderCommitsAndSurvivesReopening() throws {
        launchApp()
        createProjectViaUI(name: "Header Test")
        createEndpointViaUI(name: "Headers EP", path: "/api/headers")
        hideRequestLogDrawer()

        XCTAssertTrue(headersEmptyNote.waitForExistence(timeout: 5),
                      "A new endpoint's scenario carries no headers, so the section should say so")

        XCTAssertTrue(addHeaderButton.waitForExistence(timeout: 5),
                      "The Response headers section should offer 'Add header'")
        revealInEditor(addHeaderButton)
        addHeaderButton.click()

        XCTAssertTrue(headersEmptyNote.waitForNonExistence(timeout: 3),
                      "Adding a row should replace the 'No custom headers' state")

        let key = endpointEditor.headerKeyField(at: 0)
        let value = endpointEditor.headerValueField(at: 0)
        XCTAssertTrue(key.waitForExistence(timeout: 5), "A header name field should appear")
        XCTAssertTrue(value.waitForExistence(timeout: 5), "A header value field should appear")

        revealInEditor(key)
        key.click()
        key.typeText("X-Mimic-Source")
        revealInEditor(value)
        value.click()
        value.typeText("uitest")

        XCTAssertEqual(key.value as? String, "X-Mimic-Source",
                       "The header name field should hold what was typed into it")
        XCTAssertEqual(value.value as? String, "uitest",
                       "The header value field should hold what was typed into it")

        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recent = welcome.findRecentProject(named: "Header Test")
        XCTAssertNotNil(recent, "The project should appear in recents")
        recent!.click()
        XCTAssertTrue(workspace.assertVisible())

        let path = workspace.endpointPathText("/api/headers")
        XCTAssertTrue(path.waitForExistence(timeout: 5),
                      "The endpoint should be in the sidebar after reopening")
        path.click()

        let reopenedKey = endpointEditor.headerKeyField(at: 0)
        XCTAssertTrue(reopenedKey.waitForExistence(timeout: 5),
                      "The reopened endpoint should still have a header row")
        XCTAssertEqual(reopenedKey.value as? String, "X-Mimic-Source",
                       "The header name should have been committed to the active scenario")
        XCTAssertEqual(endpointEditor.headerValueField(at: 0).value as? String, "uitest",
                       "The header value should have been committed to the active scenario")
    }

    // MARK: - 6. Response headers: removing the middle row

    /// EPHDR-05, EPHDR-06.
    ///
    /// The regression guard for the id-vs-index removal fix. Removing by index meant every surviving
    /// row held an index the removal had just invalidated, so the rows below the deleted one showed
    /// the wrong values — the failure this asserts is absent.
    @MainActor
    func testRemovingAMiddleHeaderRowKeepsTheOthersIntact() throws {
        launchApp()
        createProjectViaUI(name: "Header Removal")
        createEndpointViaUI(name: "Headers EP", path: "/api/headers")
        hideRequestLogDrawer()

        XCTAssertTrue(addHeaderButton.waitForExistence(timeout: 5))
        revealInEditor(addHeaderButton)

        let names = ["Alpha", "Bravo", "Charlie"]
        for (index, name) in names.enumerated() {
            revealInEditor(addHeaderButton)
            addHeaderButton.click()
            let key = endpointEditor.headerKeyField(at: index)
            XCTAssertTrue(key.waitForExistence(timeout: 5), "Header row \(index) should appear")
            revealInEditor(key)
            key.click()
            key.typeText(name)

            let value = endpointEditor.headerValueField(at: index)
            revealInEditor(value)
            value.click()
            value.typeText(name.lowercased())
        }

        XCTAssertEqual(endpointEditor.headerKeyField(at: 1).value as? String, "Bravo",
                       "The middle row should hold the middle value before the removal")

        let remove = removeHeaderButton(at: 1)
        XCTAssertTrue(remove.waitForExistence(timeout: 5),
                      "Each header row should offer a remove button")
        revealInEditor(remove)
        remove.click()

        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) {
                self.endpointEditor.headerKeyField(at: 2).exists == false
            },
            "Removing a row should leave two rows behind"
        )
        XCTAssertEqual(endpointEditor.headerKeyField(at: 0).value as? String, "Alpha",
                       "The row above the removed one should keep its name")
        XCTAssertEqual(endpointEditor.headerValueField(at: 0).value as? String, "alpha",
                       "The row above the removed one should keep its value")
        XCTAssertEqual(endpointEditor.headerKeyField(at: 1).value as? String, "Charlie",
                       "The row below the removed one should move up carrying its own name, not Bravo's")
        XCTAssertEqual(endpointEditor.headerValueField(at: 1).value as? String, "charlie",
                       "The row below the removed one should move up carrying its own value")
    }

    // MARK: - 7. Response body: Format, and the commit

    /// EPBODY-01, EPBODY-02, EPBODY-03, EPBODY-05 (the empty half).
    ///
    /// Format becoming *enabled* is itself the proof the pasted text is valid, non-empty JSON —
    /// `canFormatBody` is exactly that conjunction — so a paste that arrived mangled fails here
    /// rather than passing on a weaker assertion.
    @MainActor
    func testPrettyPrintFormatsTheJSONBodyAndTheResultPersists() throws {
        launchApp()
        createProjectViaUI(name: "Body Format")
        createEndpointViaUI(name: "Body EP", path: "/api/body")
        hideRequestLogDrawer()

        let editor = bodyTextView()
        XCTAssertTrue(editor.waitForExistence(timeout: 5),
                      "The editor pane should render the response body editor")

        XCTAssertTrue(prettyPrintButton.waitForExistence(timeout: 5),
                      "The Response body section should offer 'Pretty-print JSON'")
        XCTAssertFalse(prettyPrintButton.isEnabled,
                       "Format should be disabled while the body is empty")

        setResponseBody(#"{"name":"Ada Lovelace","roles":["engineer"]}"#, expecting: "Lovelace")

        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 6) { self.prettyPrintButton.isEnabled },
            "Format should enable once the body is non-empty valid JSON"
        )

        let beforeFormatting = bodyText()
        revealInEditor(prettyPrintButton)
        prettyPrintButton.click()

        let reformatted = UITestApp.waitUntil(timeout: 5) { self.bodyText().contains("\n") }
        let afterFormatting = bodyText()
        XCTAssertTrue(reformatted,
                      "Format should re-indent the body across lines — it reads \(afterFormatting)")
        XCTAssertNotEqual(afterFormatting, beforeFormatting,
                          "Format should actually rewrite the body, not sit there enabled and inert")
        XCTAssertTrue(afterFormatting.contains("Lovelace"),
                      "Formatting must not lose the payload")

        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recent = welcome.findRecentProject(named: "Body Format")
        XCTAssertNotNil(recent, "The project should appear in recents")
        recent!.click()
        XCTAssertTrue(workspace.assertVisible())

        let path = workspace.endpointPathText("/api/body")
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click()

        let persisted = UITestApp.waitUntil(timeout: 8) { self.bodyText().contains("Lovelace") }
        let reopenedBody = bodyText()
        XCTAssertTrue(persisted,
                      "The body should have been committed to the active scenario — it reads \(reopenedBody)")
    }

    // MARK: - 8. Response body: invalid JSON

    /// EPBODY-04, EPBODY-05 (the invalid half).
    ///
    /// The warning has to say the body is *still saved*: a mock server whose job is standing in for a
    /// backend must be able to serve a malformed payload on purpose, so this is a warning rather than
    /// a refusal, and the test asserts the text rather than only the element.
    @MainActor
    func testInvalidJSONBodyWarnsAndDisablesFormat() throws {
        launchApp()
        createProjectViaUI(name: "Body Invalid")
        createEndpointViaUI(name: "Body EP", path: "/api/body")
        hideRequestLogDrawer()

        // No braces in the payload, deliberately: whatever a source editor does about matching
        // brackets, "definitely not json" is invalid and stays invalid.
        setResponseBody("definitely not json", expecting: "definitely not json")

        let warning = anyElement(identified: "ds.jsoneditor.editor.body.error")
        XCTAssertTrue(warning.waitForExistence(timeout: 6),
                      "A malformed body should raise the JSON warning after the validation settle")
        // Read from the row rather than from its first element — see `bodyWarningText()`. The row's
        // glyph is listed first and carries the whole of AppKit's "Warning", which is what the
        // original form of this assertion was comparing against.
        let saysItIsKept = UITestApp.waitUntil(timeout: 5) { self.bodyWarningText().contains("still saved") }
        let warningText = bodyWarningText()
        XCTAssertTrue(saysItIsKept,
                      "The warning should say the body is saved and served as written — it reads \(warningText)")

        XCTAssertTrue(prettyPrintButton.waitForExistence(timeout: 5))
        XCTAssertFalse(prettyPrintButton.isEnabled,
                       "Format should be disabled while the body is not valid JSON")

        XCTAssertTrue(bodyText().contains("definitely not json"),
                      "The invalid text must stay in the editor — it is not rejected, only flagged")
    }

    // MARK: - 9. Status code validation notes

    /// EPEDIT-06, EPEDIT-07.
    ///
    /// A rejected status code used to be rejected in silence — the field went on showing 600 while
    /// the endpoint went on serving what it had before. The note is the whole of the feedback, and
    /// the two messages differ: an out-of-range code states the rule, an empty field asks for a
    /// value.
    @MainActor
    func testStatusCodeValidationNotesExplainWhyACodeWasRejected() throws {
        launchApp()
        createProjectViaUI(name: "Status Validation")
        createEndpointViaUI(name: "Status EP", path: "/api/status")

        let field = endpointEditor.statusCodeField
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "The Response section should show the status code field")

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("600")

        XCTAssertTrue(statusCodeValidationNote.waitForExistence(timeout: 6),
                      "An out-of-range status code should raise the validation note once it settles")
        let statesTheRule = UITestApp.waitUntil(timeout: 5) {
            self.shownText(of: self.statusCodeValidationNote).contains("must be between 200 and 599")
        }
        let outOfRangeMessage = shownText(of: statusCodeValidationNote)
        XCTAssertTrue(statesTheRule,
                      "The note should state the rule — it reads \(outOfRangeMessage)")

        // Clearing the field is a different complaint: the endpoint is still serving a code the
        // editor has stopped showing, so the message asks for one rather than describing a bad one.
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])

        let asksForACode = UITestApp.waitUntil(timeout: 6) {
            self.shownText(of: self.statusCodeValidationNote).contains("Enter a status code")
        }
        let emptyFieldMessage = shownText(of: statusCodeValidationNote)
        XCTAssertTrue(asksForACode,
                      "An empty field should ask for a code — the note reads \(emptyFieldMessage)")

        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("404")
        XCTAssertTrue(statusCodeValidationNote.waitForNonExistence(timeout: 6),
                      "A serveable code should take the note back down")
    }

    // MARK: - 10. Group tag → sidebar sections

    /// EPEDIT-09, SIDEBAR-13, SIDEBAR-15.
    ///
    /// The group tag commits on *blur*, not on Return alone — typing a value and moving on is the
    /// ordinary way to fill a form, and without the blur commit the edit was dropped and quietly
    /// restored the next time the selection changed. Tab is what moves the focus here: the Settings
    /// card may sit below the fold, and clicking a control to blur another one is a click that has to
    /// land somewhere visible.
    @MainActor
    func testGroupTagGathersTheEndpointIntoASidebarSection() throws {
        launchApp()
        createProjectViaUI(name: "Grouping")
        createEndpointViaUI(name: "Users", path: "/api/users")
        createEndpointViaUI(name: "Health", path: "/api/health")
        hideRequestLogDrawer()

        let groupTag = endpointEditor.groupTagField
        XCTAssertTrue(groupTag.waitForExistence(timeout: 5),
                      "The Settings section should show the group tag field")
        // Read back rather than gated on `isHittable` — see `typeIntoEditorField`. The tag has to be
        // in the field before Tab can commit it, and a click that landed elsewhere reads as "the tag
        // did not commit" three assertions later if nothing checks here.
        typeIntoEditorField(groupTag, "Ops", "The Settings card's group tag field")
        app.typeKey(.tab, modifierFlags: [])

        let grouped = waitForGroupSection(named: "Ops", showing: "Ops")
        // Named in the message because the two failures look identical from the outside: a section
        // that never appeared, and a sidebar this query could not scope itself to.
        let sidebarPresence = sidebarElement.exists ? "is present" : "is not in the tree at all"
        XCTAssertTrue(
            grouped,
            "Tagging an endpoint should give the sidebar a named group section — the sidebar element "
                + sidebarPresence
        )
        XCTAssertTrue(waitForGroupSection(named: "ungrouped", showing: "Ungrouped", timeout: 5),
                      "The untagged endpoint should sit under an 'Ungrouped' section beside it")
        XCTAssertTrue(waitForSidebarRowCount(2),
                      "Grouping rearranges the rows, it does not remove any")
    }

    // MARK: - 11. A group section's rows, while a sibling is being edited

    /// SIDEBAR-13's other half: a grouped endpoint stays a *row* — the section gathers it, it does
    /// not swallow it — and the sidebar goes on navigating with sections on screen.
    ///
    /// The ungrouped endpoint is selected first, deliberately: with `/api/health` in the editor its
    /// path is on screen in the editor header too, so "the grouped endpoint is listed" would be an
    /// assertion about the editor rather than about the sidebar. Moving the editor to `/api/users`
    /// first leaves the sidebar as the only place `/api/health` can be showing.
    ///
    /// **SIDEBAR-14 — collapsing a group section — is deliberately not claimed here, and this test
    /// was cut back to say only what it can prove.** The collapse itself is real:
    /// `SidebarView.sectionBinding(for:)` writes `collapsedSections`, and
    /// `SidebarView.updatedCollapsedSections` is unit-tested. What is missing is a way to *reach* it.
    /// `Section(isExpanded:)` draws SwiftUI's own disclosure, the app declares no control there and
    /// so gives it no identifier, and a CI round proved that neither clicking the header row nor
    /// hovering it for AppKit's "Hide"/"Show" button toggles the section from a test. The production
    /// fix is an identified affordance of the app's own in `SidebarView`'s section header —
    /// `.accessibilityIdentifier("sidebar.group.<name>.disclosure")` on a control that flips the same
    /// binding — and that is a change to the window, not something a test should reach around with a
    /// coordinate click at a guessed point. `.pathfinder/journeys.json` already records SIDEBAR-14 as
    /// untested with this reason; it stays that way until the window offers a name.
    @MainActor
    func testAGroupSectionKeepsItsEndpointListedWhileASiblingIsEdited() throws {
        launchApp()
        createProjectViaUI(name: "Grouped rows")
        createEndpointViaUI(name: "Users", path: "/api/users")
        createEndpointViaUI(name: "Health", path: "/api/health")
        hideRequestLogDrawer()

        let groupTag = endpointEditor.groupTagField
        typeIntoEditorField(groupTag, "Ops", "The Settings card's group tag field")
        app.typeKey(.tab, modifierFlags: [])

        XCTAssertTrue(waitForGroupSection(named: "Ops", showing: "Ops"),
                      "The tagged endpoint should be under a group header")

        // With /api/health in the editor, /api/users can only be the sidebar's row.
        let usersRow = workspace.endpointPathText("/api/users")
        XCTAssertTrue(usersRow.waitForExistence(timeout: 5))
        usersRow.click()
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) {
                self.shownText(of: self.endpointEditor.pathLabel).contains("/api/users")
            },
            "Clicking the ungrouped row should move the editor to it"
        )

        let healthPath = app.staticTexts["/api/health"]
        XCTAssertTrue(healthPath.waitForExistence(timeout: 5),
                      "The grouped endpoint should still be listed under its section while its "
                          + "ungrouped sibling is the one being edited")
    }

    // MARK: - 12. Per-endpoint delay

    /// EPEDIT-10, EPEDIT-11.
    ///
    /// `EndpointEditorPage.delayField` had no caller. The delay commits on blur, and the invalid case
    /// used to be a bare `guard … else { return }`: the field kept the text, the endpoint kept its
    /// old delay, and nothing said so.
    @MainActor
    func testEndpointDelayCommitsOnBlurAndRejectsANonNumericValue() throws {
        launchApp()
        createProjectViaUI(name: "Delay Test")
        createEndpointViaUI(name: "Slow EP", path: "/api/slow")
        hideRequestLogDrawer()

        let delay = endpointEditor.delayField
        XCTAssertTrue(delay.waitForExistence(timeout: 5),
                      "The Settings section should show the per-endpoint delay field")
        revealInEditor(delay)
        delay.click()
        delay.typeKey("a", modifierFlags: .command)
        delay.typeText("250")
        app.typeKey(.tab, modifierFlags: [])

        XCTAssertFalse(delayValidationNote.exists,
                       "A whole number of milliseconds should raise no complaint")

        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recent = welcome.findRecentProject(named: "Delay Test")
        XCTAssertNotNil(recent, "The project should appear in recents")
        recent!.click()
        XCTAssertTrue(workspace.assertVisible())

        let path = workspace.endpointPathText("/api/slow")
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click()

        let reopenedDelay = endpointEditor.delayField
        XCTAssertTrue(reopenedDelay.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedDelay.value as? String, "250",
                       "Blurring the delay field should have committed the value to the endpoint")

        hideRequestLogDrawer()
        revealInEditor(reopenedDelay)
        reopenedDelay.click()
        reopenedDelay.typeKey("a", modifierFlags: .command)
        reopenedDelay.typeText("abc")
        app.typeKey(.tab, modifierFlags: [])

        XCTAssertTrue(delayValidationNote.waitForExistence(timeout: 5),
                      "A non-numeric delay should say why it was not accepted")
        let delayMessage = shownText(of: delayValidationNote)
        XCTAssertTrue(delayMessage.contains("whole number of milliseconds"),
                      "The note should state the rule — it reads \(delayMessage)")
    }

    // MARK: - 13. The global delay row

    /// EPEDIT-12, EPEDIT-13.
    ///
    /// The row is deliberately *not* a disabled text field — a greyed-out well in a row of live ones
    /// reads as a control that failed — so "there is no field here" is part of what is being
    /// asserted, and the note beside it is the only thing explaining why.
    ///
    /// **The number itself is not asserted, and that is a production gap rather than a choice.**
    /// `EndpointEditorView` builds the row as `Text("\(globalDelayMs)")` *and* gives it
    /// `.accessibilityLabel("Global delay in milliseconds")` — and an explicit label *replaces* what
    /// a `Text` exposes rather than adding to it. CI read this element as label `""`, value `"Global
    /// delay in milliseconds"`: the digits are nowhere in the tree, and VoiceOver announces the row
    /// as a label with no value under it, which is the same defect heard rather than queried. The
    /// fix is one modifier on that `Text` — `.accessibilityValue("\(globalDelayMs)")` — after which
    /// this test should assert the row reads `0` for a fresh project. Asserting it before then would
    /// only be asserting the label back to itself.
    @MainActor
    func testGlobalDelayRowIsReadOnlyAndExplainsItself() throws {
        launchApp()
        createProjectViaUI(name: "Global Delay")
        createEndpointViaUI(name: "Any EP", path: "/api/any")
        hideRequestLogDrawer()

        XCTAssertTrue(globalDelayValue.waitForExistence(timeout: 5),
                      "The Settings section should show the project-wide delay")
        let globalDelayText = shownText(of: globalDelayValue)
        XCTAssertTrue(globalDelayText.contains("Global delay"),
                      "The row should say which delay it is showing — it reads \(globalDelayText)")
        XCTAssertFalse(app.textFields["endpointEditor.globalDelay"].exists,
                       "The global delay is shown, not edited — it must not be a text field")

        XCTAssertTrue(globalDelayNote.waitForExistence(timeout: 5),
                      "The row should carry the note explaining where the global delay comes from")
        let noteText = shownText(of: globalDelayNote)
        XCTAssertTrue(noteText.contains("--delay"),
                      "The note should name the command that sets it — it reads \(noteText)")
    }

    // MARK: - 14. Adding a scenario from the inspector

    /// SCENNEW-01, SCENNEW-02, SCENNEW-03, SCENNEW-04, SCENNEW-05.
    ///
    /// `NewScenarioSheetPage` has existed, been instantiated on every launch, and never been opened
    /// by a test. This is the first time the sheet is driven at all.
    @MainActor
    func testAddScenarioSheetAddsAScenarioToTheInspectorList() throws {
        launchApp()
        createProjectViaUI(name: "Scenario Add")
        createEndpointViaUI(name: "Scenario EP", path: "/api/scenarios")

        XCTAssertTrue(addScenarioButton.waitForExistence(timeout: 5),
                      "The inspector header should offer 'Add scenario' while showing the Scenarios tab")
        addScenarioButton.click()

        XCTAssertTrue(newScenarioSheet.nameField.waitForExistence(timeout: 5),
                      "The new-scenario sheet should appear")
        XCTAssertFalse(newScenarioSheet.createButton.isEnabled,
                       "'Add scenario' should be disabled while the name is blank")

        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText("   ")
        XCTAssertFalse(newScenarioSheet.createButton.isEnabled,
                       "'Add scenario' should stay disabled for a whitespace-only name")

        newScenarioSheet.nameField.typeKey("a", modifierFlags: .command)
        newScenarioSheet.nameField.typeText("Unauthorized")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 3) { self.newScenarioSheet.createButton.isEnabled },
            "'Add scenario' should enable once the name is real"
        )
        newScenarioSheet.createButton.click()

        XCTAssertTrue(newScenarioSheet.nameField.waitForNonExistence(timeout: 3),
                      "Confirming should dismiss the sheet")
        XCTAssertTrue(inspector.scenarioRow(named: "Unauthorized").waitForExistence(timeout: 5),
                      "The new scenario should appear in the inspector's list")
        XCTAssertTrue(inspector.scenarioRow(named: "Default").exists,
                      "Adding a scenario should not disturb the existing one")
    }

    // MARK: - 15. The new-scenario sheet's Cancel and Return

    /// SCENNEW-06, SCENNEW-07.
    @MainActor
    func testNewScenarioSheetCancelsAndSubmitsOnReturn() throws {
        launchApp()
        createProjectViaUI(name: "Scenario Keys")
        createEndpointViaUI(name: "Scenario EP", path: "/api/scenarios")

        XCTAssertTrue(addScenarioButton.waitForExistence(timeout: 5))
        addScenarioButton.click()
        XCTAssertTrue(newScenarioSheet.nameField.waitForExistence(timeout: 5),
                      "The new-scenario sheet should appear")

        // Named before cancelling, so "Cancel adds nothing" is a claim about a scenario that was
        // actually described rather than about a string nobody typed.
        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText("Discarded")
        XCTAssertTrue(newScenarioSheet.cancelButton.waitForExistence(timeout: 3),
                      "The new-scenario sheet should offer Cancel")
        newScenarioSheet.cancelButton.click()

        XCTAssertTrue(newScenarioSheet.nameField.waitForNonExistence(timeout: 3),
                      "Cancel should dismiss the sheet")
        XCTAssertFalse(inspector.scenarioRow(named: "Discarded").waitForExistence(timeout: 2),
                       "Cancel should add nothing, however far the name was typed")

        addScenarioButton.click()
        XCTAssertTrue(newScenarioSheet.nameField.waitForExistence(timeout: 5))
        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText("Server error")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(inspector.scenarioRow(named: "Server error").waitForExistence(timeout: 5),
                      "Return should submit the sheet and add the scenario")
    }

    // MARK: - 16. Activating a scenario moves the marker off the old one

    /// SCEN-06, SCEN-07.
    ///
    /// `testSwitchActiveScenarioViaClick` asserts the clicked row reads active and stops there, so
    /// nothing has ever proved the marker *left* the previous scenario. Read from the row's
    /// accessibility value, which says "inactive" out loud; the label only gains an "active" clause
    /// and so can never report the negative.
    @MainActor
    func testActivatingAScenarioMovesTheActiveMarkerOffThePreviousOne() throws {
        launchApp()
        createProjectViaUI(name: "Scenario Switch")
        createEndpointViaUI(name: "Scenario EP", path: "/api/scenarios")

        XCTAssertTrue(addScenarioButton.waitForExistence(timeout: 5))
        addScenarioButton.click()
        XCTAssertTrue(newScenarioSheet.nameField.waitForExistence(timeout: 5))
        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText("Unauthorized")
        newScenarioSheet.createButton.click()

        let added = inspector.scenarioRow(named: "Unauthorized")
        XCTAssertTrue(added.waitForExistence(timeout: 5))

        XCTAssertTrue(waitForScenarioValue("active", named: "Default"),
                      "The endpoint's first scenario stays active when a second is added")
        XCTAssertTrue(waitForScenarioValue("inactive", named: "Unauthorized"),
                      "A newly added scenario is not activated by being added")

        added.click()

        XCTAssertTrue(waitForScenarioValue("active", named: "Unauthorized"),
                      "Clicking a scenario should activate it")
        XCTAssertTrue(waitForScenarioValue("inactive", named: "Default"),
                      "Activating one scenario should take the marker off the other")
    }

    // MARK: - 17. A scenario row announces its status code

    /// SCEN-03.
    ///
    /// The status pill sets no identifier, and the row is `.accessibilityElement(children: .combine)`
    /// so a child identifier would be swallowed anyway — the row's own spoken label is the reachable
    /// statement of the code. Changing the code in the editor and watching the row follow is what
    /// makes this an assertion about the pill rather than about the constant 200.
    @MainActor
    func testScenarioRowAnnouncesItsStatusCodeAndTracksEdits() throws {
        launchApp()
        createProjectViaUI(name: "Scenario Status")
        createEndpointViaUI(name: "Scenario EP", path: "/api/scenarios")

        let row = inspector.scenarioRow(named: "Default")
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The endpoint's Default scenario should be listed")
        XCTAssertTrue(row.label.contains("status 200"),
                      "The row should speak its status code — it reads \(row.label)")

        let field = endpointEditor.statusCodeField
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("503")

        let followed = UITestApp.waitUntil(timeout: 8) {
            self.inspector.scenarioRow(named: "Default").label.contains("status 503")
        }
        let rowLabel = inspector.scenarioRow(named: "Default").label
        XCTAssertTrue(followed,
                      "The scenario row should follow the edited status code — it reads \(rowLabel)")
    }

    // MARK: - 18. Deleting a scenario

    /// SCEN-04, SCENDEL-01, SCENDEL-02, SCENDEL-03.
    ///
    /// The disabled case comes first because it is the one that cannot be set up afterwards: once a
    /// second scenario exists the endpoint never goes back to having one.
    @MainActor
    func testDeleteScenarioIsDisabledForTheOnlyScenarioAndRemovesOneOfSeveral() throws {
        launchApp()
        createProjectViaUI(name: "Scenario Delete")
        createEndpointViaUI(name: "Scenario EP", path: "/api/scenarios")

        let defaultRow = inspector.scenarioRow(named: "Default")
        XCTAssertTrue(defaultRow.waitForExistence(timeout: 5))
        defaultRow.rightClick()

        let deleteItem = app.menuItems["Delete scenario"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5),
                      "The scenario row's context menu should offer 'Delete scenario'")
        XCTAssertFalse(deleteItem.isEnabled,
                       "Deleting the endpoint's only scenario would leave it serving nothing, so it is disabled")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(addScenarioButton.waitForExistence(timeout: 5))
        addScenarioButton.click()
        XCTAssertTrue(newScenarioSheet.nameField.waitForExistence(timeout: 5))
        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText("Unauthorized")
        newScenarioSheet.createButton.click()

        let addedRow = inspector.scenarioRow(named: "Unauthorized")
        XCTAssertTrue(addedRow.waitForExistence(timeout: 5))

        addedRow.rightClick()
        let secondDelete = app.menuItems["Delete scenario"]
        XCTAssertTrue(secondDelete.waitForExistence(timeout: 5))
        XCTAssertTrue(secondDelete.isEnabled,
                      "With two scenarios, deleting one is allowed")
        secondDelete.click()

        XCTAssertTrue(addedRow.waitForNonExistence(timeout: 5),
                      "The deleted scenario should leave the inspector's list")
        XCTAssertTrue(inspector.scenarioRow(named: "Default").exists,
                      "The scenario that was not deleted should still be there")
    }

    // MARK: - 19. The filter's clear button and its no-matches row

    /// SIDEBAR-09, SIDEBAR-12.
    ///
    /// `testSidebarSearchFiltersEndpoints` asserts only that the no-matches message is *absent* for a
    /// query that matches — a negative assertion, which is no coverage of the state appearing. The
    /// clear button is matched by label: `DSFilterField` pairs its container identifier with
    /// `.contain`, and its own doc records that the `.field`/`.scope`/`.clear` names never win.
    @MainActor
    func testFilterClearButtonRestoresTheListAfterANoMatchesQuery() throws {
        launchApp()
        createProjectViaUI(name: "Filter Clear")
        createEndpointViaUI(name: "Users", path: "/api/users")

        XCTAssertTrue(sidebarFilterField.waitForExistence(timeout: 5),
                      "A project with endpoints should show the sidebar filter field")
        sidebarFilterField.click()
        sidebarFilterField.typeText("zzz")

        // The sidebar debounces the search by 300ms before it re-sections.
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 6) { self.sidebarReportsNoMatches(saying: "No endpoints match") },
            "A query that matches nothing should say so rather than showing a blank panel"
        )
        XCTAssertTrue(sidebarReportsNoMatches(saying: "zzz"),
                      "The message should quote the query that emptied the list")

        let clearButton = app.buttons["Clear filter"].firstMatch
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5),
                      "A non-empty filter should offer a clear button")
        clearButton.click()

        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 6) { self.sidebarNoMatchesRow.exists == false },
            "Clearing the filter should bring the list back"
        )
        XCTAssertTrue(waitForSidebarRowCount(1),
                      "The endpoint should be listed again once the query is gone")
        XCTAssertEqual(sidebarFilterField.value as? String ?? "", "",
                       "Clearing should empty the field, not merely re-run the query")
    }

    // MARK: - 20. The filter's method scope

    /// SIDEBAR-10, SIDEBAR-11.
    ///
    /// Scoping to a method with no endpoints is the case the old "no matches" condition could not
    /// describe: both arrays empty while the search text is still "", which used to fall through and
    /// render a list with nothing in it. The sentence is what distinguishes the fix from the bug.
    @MainActor
    func testMethodScopeFilterRestrictsTheListAndNamesTheEmptyScope() throws {
        launchApp()
        createProjectViaUI(name: "Filter Scope")
        createEndpointViaUI(name: "Users", path: "/api/users")

        XCTAssertTrue(sidebarFilterScopeMenu.waitForExistence(timeout: 5),
                      "The sidebar filter should offer a method scope")
        sidebarFilterScopeMenu.click()

        let deleteScope = app.menuItems["DELETE"]
        XCTAssertTrue(deleteScope.waitForExistence(timeout: 5),
                      "The scope menu should list the HTTP methods")
        deleteScope.click()

        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 6) { self.sidebarReportsNoMatches(saying: "No DELETE endpoints") },
            "Scoping to a method the project has none of should name that scope, not go blank"
        )

        sidebarFilterScopeMenu.click()
        let getScope = app.menuItems["GET"]
        XCTAssertTrue(getScope.waitForExistence(timeout: 5))
        getScope.click()

        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 6) { self.sidebarNoMatchesRow.exists == false },
            "Scoping to the method the endpoint actually is should bring it back"
        )
        XCTAssertTrue(waitForSidebarRowCount(1),
                      "The GET endpoint should be listed under the GET scope")
    }

    // MARK: - 21. The sidebar row's context menu — Duplicate

    /// SIDEBAR-16, EPDUP-03, EPDUP-04.
    ///
    /// The row is right-clicked through its `endpoint-<uuid>` identifier rather than through its path
    /// text: the editor header shows the same path, and right-clicking *that* opens no menu at all —
    /// a failure that would read as "the context menu is broken".
    @MainActor
    func testSidebarContextMenuDuplicatesAnEndpoint() throws {
        launchApp()
        createProjectViaUI(name: "Sidebar Duplicate")
        createEndpointViaUI(name: "Orders", path: "/api/orders")

        XCTAssertTrue(waitForSidebarRowCount(1), "The project should start with one endpoint row")
        let rows = sidebarEndpointRows()
        rows[0].rightClick()

        XCTAssertTrue(app.menuItems["Duplicate"].waitForExistence(timeout: 5),
                      "The row's context menu should offer Duplicate")
        XCTAssertTrue(app.menuItems["Delete endpoint\u{2026}"].exists,
                      "The row's context menu should offer Delete endpoint…")
        app.menuItems["Duplicate"].click()

        XCTAssertTrue(waitForSidebarRowCount(2),
                      "Duplicating should add a second row to the sidebar")
        XCTAssertTrue(app.staticTexts["Orders (Copy)"].waitForExistence(timeout: 5),
                      "The copy should be listed under its own name")
    }

    // MARK: - 22. The sidebar row's context menu — Delete

    /// EPDEL-05, EPDEL-06.
    ///
    /// A different path from the editor's more-menu delete, and a different confirmation: the
    /// sidebar's names the endpoint (`Delete "Orders"?`) where the editor's is the generic "Delete
    /// endpoint?". The interpolated name is what tells the two apart, so it is what is asserted.
    @MainActor
    func testSidebarContextMenuDeleteConfirmationNamesTheEndpoint() throws {
        launchApp()
        createProjectViaUI(name: "Sidebar Delete")
        createEndpointViaUI(name: "Orders", path: "/api/orders")

        XCTAssertTrue(waitForSidebarRowCount(1), "The project should start with one endpoint row")
        var rows = sidebarEndpointRows()
        rows[0].rightClick()

        let deleteItem = app.menuItems["Delete endpoint\u{2026}"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5),
                      "The row's context menu should offer Delete endpoint…")
        deleteItem.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "Deleting from the sidebar should ask for confirmation")
        // The title may arrive as the sheet's own label or as a `StaticText` inside it, so both are
        // polled — which of the two AppKit uses for an alert title is not something to guess at.
        let namesTheEndpoint = UITestApp.waitUntil(timeout: 4) {
            sheet.label.contains("Orders")
                || sheet.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Orders", "Orders")
                ).firstMatch.exists
        }
        XCTAssertTrue(namesTheEndpoint,
                      "The sidebar's confirmation should name the endpoint it is about to remove")

        XCTAssertTrue(sheet.buttons["Cancel"].waitForExistence(timeout: 3),
                      "The confirmation should offer a way out")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(waitForSidebarRowCount(1),
                      "Cancelling the sidebar's confirmation should keep the endpoint")

        rows = sidebarEndpointRows()
        rows[0].rightClick()
        let secondDelete = app.menuItems["Delete endpoint\u{2026}"]
        XCTAssertTrue(secondDelete.waitForExistence(timeout: 5))
        secondDelete.click()

        let confirmSheet = app.sheets.firstMatch
        XCTAssertTrue(confirmSheet.buttons["Delete"].waitForExistence(timeout: 5))
        confirmSheet.buttons["Delete"].click()

        XCTAssertTrue(workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
                      "Deleting the last endpoint should return the sidebar to its empty state")
    }

    // MARK: - 23. The editor's more menu — Duplicate

    /// EPDUP-01, EPDUP-02, EPDUP-03.
    ///
    /// `testDeleteEndpointWithConfirmation` opens this menu and clicks straight past Duplicate.
    /// Unlike the sidebar's copy, the editor's duplicate deliberately leaves the selection where it
    /// was — `CenterPaneView` discards the returned endpoint — so what is asserted here is the new
    /// row, not a moved selection.
    @MainActor
    func testEditorMoreMenuDuplicatesTheEndpoint() throws {
        launchApp()
        createProjectViaUI(name: "Editor Duplicate")
        createEndpointViaUI(name: "Orders", path: "/api/orders")

        XCTAssertTrue(endpointEditor.moreMenu.waitForExistence(timeout: 5),
                      "The editor header should offer its more-actions menu")
        endpointEditor.moreMenu.click()

        let duplicate = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5),
                      "The more-actions menu should offer Duplicate")
        duplicate.click()

        XCTAssertTrue(waitForSidebarRowCount(2),
                      "Duplicating from the editor should add a row to the sidebar")
        XCTAssertTrue(app.staticTexts["Orders (Copy)"].waitForExistence(timeout: 5),
                      "The copy should be listed under its own name")
    }

    // MARK: - 24. The editor's delete confirmation, cancelled

    /// EPDEL-04.
    ///
    /// The confirmed path is covered; the refused one was not, and "Cancel does nothing" is the half
    /// a destructive dialog exists for.
    @MainActor
    func testEditorDeleteConfirmationCancelKeepsTheEndpoint() throws {
        launchApp()
        createProjectViaUI(name: "Editor Delete Cancel")
        createEndpointViaUI(name: "Keep Me", path: "/api/keep")

        XCTAssertTrue(endpointEditor.moreMenu.waitForExistence(timeout: 5))
        endpointEditor.moreMenu.click()

        let deleteItem = app.menuItems["Delete endpoint\u{2026}"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.buttons["Cancel"].waitForExistence(timeout: 5),
                      "The editor's delete confirmation should offer Cancel")
        sheet.buttons["Cancel"].click()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3),
                      "Cancel should dismiss the confirmation")
        XCTAssertTrue(waitForSidebarRowCount(1),
                      "Cancelling should leave the endpoint in the sidebar")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) {
                self.shownText(of: self.endpointEditor.pathLabel).contains("/api/keep")
            },
            "Cancelling should leave the endpoint open in the editor"
        )
        XCTAssertFalse(workspace.sidebarEmptyHeading.exists,
                       "The sidebar must not fall back to its empty state")
    }
}
