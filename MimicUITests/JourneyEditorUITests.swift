import AppKit
import Foundation
import XCTest

// MARK: - Locator helpers

/// Resolves a control by identifier, then by label, then by a loose descendant match.
///
/// The three-step chain is `EndpointEditorPage.moreMenu`'s, and it exists for the reason
/// `references/accessibility-tree.md` gives: whether a leaf keeps its own identifier depends on how
/// SwiftUI collapses the subtree above it, and a query that assumes it did is a query that fails as
/// "the app is broken" rather than "the tree is shaped differently than I guessed".
///
/// It never *skips*: when nothing matches, the last branch returns a query that resolves to nothing,
/// so the caller's `waitForExistence` fails loudly instead of the test quietly passing.
@MainActor
private func resolveJourneyControl(
    _ app: XCUIApplication,
    identifier: String,
    label: String,
    type: XCUIElement.ElementType
) -> XCUIElement {
    let byIdentifier = app.descendants(matching: type).matching(identifier: identifier).firstMatch
    if byIdentifier.exists { return byIdentifier }
    let byLabel = app.descendants(matching: type)
        .matching(NSPredicate(format: "label == %@", label))
        .firstMatch
    if byLabel.exists { return byLabel }
    return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
}

// MARK: - Page object extensions
//
// The journeys suite's four page objects already carry the handles the original tests needed. These
// extensions add the ones the coverage sweep needs, in the file that uses them, so `JourneyUITests`
// stays untouched and there is still exactly one page object per surface — two structs describing
// the same navigator is how a suite starts disagreeing with itself about what an element is called.

extension JourneysNavigatorPage {

    /// The journey's one-line summary in the editor header, beside its name.
    var editorSummary: XCUIElement {
        let byStaticText = app.staticTexts["journeyEditor.summary"].firstMatch
        if byStaticText.exists { return byStaticText }
        return app.descendants(matching: .any).matching(identifier: "journeyEditor.summary").firstMatch
    }

    // MARK: Behaviour band

    var matchModePicker: XCUIElement {
        resolveJourneyControl(
            app,
            identifier: "journeyEditor.matchModePicker",
            label: "Match mode",
            type: .popUpButton
        )
    }

    var completionPicker: XCUIElement {
        resolveJourneyControl(
            app,
            identifier: "journeyEditor.completionPicker",
            label: "On completion",
            type: .popUpButton
        )
    }

    var unmatchedPicker: XCUIElement {
        resolveJourneyControl(
            app,
            identifier: "journeyEditor.unmatchedPicker",
            label: "Unscripted requests",
            type: .popUpButton
        )
    }

    var autoAdvanceToggle: XCUIElement {
        resolveJourneyControl(
            app,
            identifier: "journeyEditor.autoAdvanceToggle",
            label: "Advance automatically",
            type: .checkBox
        )
    }

    // MARK: Empty states
    //
    // `DSEmptyState` pairs its identifier with `.contain` and still flattens its leaves, so the
    // heading arrives as the container's own text and the call to action is reachable only by label.

    /// The whole "No steps yet" block, matched on the prefix `DSEmptyState` builds from its identifier.
    var stepsEmptyState: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ds.empty.journeyEditor.steps"))
            .firstMatch
    }

    /// The steps empty state's own call to action.
    ///
    /// "Add step\u{2026}", with the ellipsis, which is what separates it from the header's button:
    /// that one carries an explicit `.accessibilityLabel("Add step")` with no ellipsis, so the two
    /// controls that open the identical sheet have two distinct spoken names. It is matched by that
    /// label rather than by an identifier because `DSEmptyState` stamps `ds.empty.journeyEditor.steps`
    /// over the `ds.button.empty.journeyEditor.steps.cta` its `DSButton` sets — rule 8, and neither
    /// spelling is dependable.
    ///
    /// **Scoped to the empty state**, which is the part that was missing. `app.buttons[…].firstMatch`
    /// searches the whole window and takes the first element in tree order, and a container comes
    /// before the leaves it lends its name to: the query resolved to a wrapper whose frame is the
    /// whole block, so the synthesized click landed in the middle of the message text, reported no
    /// error, and opened nothing — the failure read "The step sheet should open". `descendants`
    /// starts *below* the element it is asked of, so this resolves to the button or to nothing.
    var stepsEmptyStateAddButton: XCUIElement {
        let scoped = stepsEmptyState.descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@", "Add step\u{2026}"))
            .firstMatch
        if scoped.exists { return scoped }
        return app.buttons["Add step\u{2026}"].firstMatch
    }

    /// The centre pane when the journeys navigator has nothing selected.
    var noJourneySelectionEmptyState: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ds.empty.center.noJourneySelection"))
            .firstMatch
    }

    // MARK: Editor run readout

    /// "Not active — endpoints answer directly", or where the run has got to.
    var runProgressReadout: XCUIElement {
        let byStaticText = app.staticTexts["journeyRun.progress"].firstMatch
        if byStaticText.exists { return byStaticText }
        return app.descendants(matching: .any).matching(identifier: "journeyRun.progress").firstMatch
    }

    // MARK: Navigator rows

    /// One journey's row in the navigator, by name.
    ///
    /// Not `journeyRow(named:)`: that matches *any* element whose label contains the name, and the
    /// editor header's `journeyEditor.name` carries the same string — so with a journey selected it
    /// can resolve to the centre pane instead of the sidebar, which is exactly the state every test
    /// below is in. Pinning the row identifier's prefix as well makes it the row or nothing.
    func row(named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "journeys.row.",
                name
            ))
            .firstMatch
    }

    /// The activation ring inside a row — the control that starts a journey *without* selecting it.
    /// Its label flips with the state, which is the whole assertion in `JRN-07`/`JRN-08`.
    func activationRing(activateNamed name: String) -> XCUIElement {
        app.buttons["Activate \(name)"].firstMatch
    }

    func activationRing(deactivateNamed name: String) -> XCUIElement {
        app.buttons["Deactivate \(name)"].firstMatch
    }

    // MARK: Navigator run strip

    /// The "a journey is answering" banner above the list.
    var runStrip: XCUIElement {
        let byIdentifier = app.descendants(matching: .any)
            .matching(identifier: "journeys.runControls")
            .firstMatch
        if byIdentifier.exists { return byIdentifier }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Running journey "))
            .firstMatch
    }

    /// A button inside the run strip.
    ///
    /// **Scoped on purpose.** `journeys.deactivateButton`'s label is "Deactivate journey" and so is
    /// `JourneyRunControls`' — two controls, same words, both on screen whenever a journey is
    /// running with its editor open, which is the state of every test that adds a journey from a
    /// template. Searching inside the strip is the disambiguation; the identifier fallback is the
    /// second one, and the two identifiers *are* distinct (`journeys.deactivateButton` versus
    /// `journeyRun.deactivateButton`) even though the labels are not.
    func runStripButton(identifier: String, label: String) -> XCUIElement {
        let scoped = runStrip.descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        if scoped.exists { return scoped }
        return app.descendants(matching: .button).matching(identifier: identifier).firstMatch
    }

    var runStripRestartButton: XCUIElement {
        runStripButton(identifier: "journeys.restartButton", label: "Restart journey")
    }

    var runStripAdvanceButton: XCUIElement {
        runStripButton(identifier: "journeys.advanceButton", label: "Advance journey")
    }

    var runStripDeactivateButton: XCUIElement {
        runStripButton(identifier: "journeys.deactivateButton", label: "Deactivate journey")
    }

    /// The strip's progress line, when it kept its own identifier through the strip's `.contain`.
    var runStripProgress: XCUIElement {
        runStrip.descendants(matching: .staticText)
            .matching(identifier: "journeys.runStrip.progress")
            .firstMatch
    }

    /// The strip's journey name, on the same terms as ``runStripProgress``.
    var runStripName: XCUIElement {
        runStrip.descendants(matching: .staticText)
            .matching(identifier: "journeys.runStrip.name")
            .firstMatch
    }
}

extension JourneyStepSheetPage {

    /// "Add step" or "Edit step" — one identifier for both wordings, so the label is the assertion.
    var title: XCUIElement {
        let byStaticText = app.staticTexts["stepSheet.title"].firstMatch
        if byStaticText.exists { return byStaticText }
        return app.descendants(matching: .any).matching(identifier: "stepSheet.title").firstMatch
    }

    var methodPicker: XCUIElement {
        resolveJourneyControl(
            app,
            identifier: "stepSheet.methodPicker",
            label: "HTTP method",
            type: .popUpButton
        )
    }

    /// A vertical-axis `TextField` may realize as either a text field or a text view depending on how
    /// AppKit backs it, so both are tried before the loose match.
    var headersField: XCUIElement {
        let byTextField = app.textFields["stepSheet.headersField"].firstMatch
        if byTextField.exists { return byTextField }
        let byTextView = app.textViews["stepSheet.headersField"].firstMatch
        if byTextView.exists { return byTextView }
        return app.descendants(matching: .any).matching(identifier: "stepSheet.headersField").firstMatch
    }

    var headersHint: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "stepSheet.headersHint").firstMatch
    }

    var bodyField: XCUIElement {
        let byTextField = app.textFields["stepSheet.bodyField"].firstMatch
        if byTextField.exists { return byTextField }
        let byTextView = app.textViews["stepSheet.bodyField"].firstMatch
        if byTextView.exists { return byTextView }
        return app.descendants(matching: .any).matching(identifier: "stepSheet.bodyField").firstMatch
    }

    var delayField: XCUIElement { app.textFields["stepSheet.delayField"] }
    var repeatField: XCUIElement { app.textFields["stepSheet.repeatField"] }

    var dropHint: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "stepSheet.dropHint").firstMatch
    }

    var timeoutHint: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "stepSheet.timeoutHint").firstMatch
    }
}

extension NewJourneySheetPage {

    var title: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newJourney.title").firstMatch
    }

    var explanation: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newJourney.explanation").firstMatch
    }
}

// MARK: - Tests

/// The half of the journeys feature `JourneyUITests` does not reach: the behaviour band, the step
/// sheet's fields and its six refusals, the step context menu, the run controls actually being
/// *driven*, the navigator's run strip, and duplicate/delete.
///
/// Two habits separate these from the original suite, and both come out of reading it:
///
/// - **Clicking is not the same as finding.** `testActivatingAJourneyEnablesRunControls` asserts
///   `restartButton.isEnabled` and stops there, so the cursor mutations behind Restart and Advance
///   have never run in a UI test. Every run control here is clicked and the readout it is supposed
///   to move is asserted afterwards.
/// - **A conditional interaction is not coverage.** Nothing below wraps a click in `if
///   element.exists`; where an element might realize two ways the locator tries both and the
///   assertion is unconditional, so a missing control fails the test rather than skipping it.
final class JourneyEditorUITests: MimicUITestCase {

    // MARK: - Pages
    //
    // Computed rather than stored: the base class builds `app` lazily inside `launchApp()`, and a
    // stored page object would have to be assigned after every launch. A page object is a struct
    // wrapping one reference, so rebuilding it per access costs nothing.

    @MainActor private var journeys: JourneysNavigatorPage { JourneysNavigatorPage(app: app) }
    @MainActor private var templatePicker: JourneyTemplatePickerPage { JourneyTemplatePickerPage(app: app) }
    @MainActor private var newJourneySheet: NewJourneySheetPage { NewJourneySheetPage(app: app) }
    @MainActor private var stepSheet: JourneyStepSheetPage { JourneyStepSheetPage(app: app) }

    /// Port 0 for the control plane, matching `JourneyUITests`: the OS picks, so a run collides
    /// neither with a developer's running instance nor with a second run on the same machine. The
    /// discovery-file half of the isolation is exported by the launch contract itself.
    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
    }

    // MARK: - Fixtures

    @MainActor
    private func launchWithProject(named name: String = "Journey Editor Tests") {
        launchApp()
        createProjectViaUI(name: name)
    }

    /// Switches the navigator to Journeys through the menu command, as `JourneyUITests` does — the
    /// `navigatorRequest` hop is the part that changed when the separate journeys window was removed,
    /// and clicking the tab directly would leave it untested.
    @MainActor
    private func showJourneysNavigator() {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5), "Menu bar should exist")

        let journeysMenu = menuBar.menuBarItems["Journeys"]
        XCTAssertTrue(journeysMenu.waitForExistence(timeout: 5), "Journeys menu should exist")
        journeysMenu.click()

        let showItem = app.menuItems["Show Journeys"].firstMatch
        XCTAssertTrue(showItem.waitForExistence(timeout: 5), "Show Journeys item should exist")
        showItem.click()

        XCTAssertTrue(journeys.waitUntilVisible(), "Journeys navigator should appear in the sidebar")
    }

    /// Adds a journey from the built-in shelf, asserting the toggle's state on the way through.
    ///
    /// Only the first four templates are added this way. The shelf's list is 320pt tall and a
    /// template row is roughly 70, so anything past the fourth needs scrolling before it can be
    /// clicked — `testTemplateShelfListsEveryTemplateAndCancels` walks the rest with the keyboard.
    @MainActor
    private func addTemplate(_ id: String, activate: Bool) {
        journeys.addButton.click()
        XCTAssertTrue(
            journeys.templateMenuItem.waitForExistence(timeout: 5),
            "The add menu should offer the template shelf"
        )
        journeys.templateMenuItem.click()

        XCTAssertTrue(templatePicker.addButton.waitForExistence(timeout: 5), "Template picker should open")

        let row = templatePicker.template(id)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Template \(id) should be listed")
        row.click()

        XCTAssertTrue(
            templatePicker.activateToggle.waitForExistence(timeout: 3),
            "The picker should offer to activate the journey it adds"
        )
        XCTAssertEqual(
            templatePicker.activateToggle.value as? Int,
            1,
            "\"Activate once added\" should default to on"
        )
        if !activate {
            templatePicker.activateToggle.click()
            XCTAssertEqual(
                templatePicker.activateToggle.value as? Int,
                0,
                "Clicking the toggle should turn it off"
            )
        }

        templatePicker.addButton.click()
        XCTAssertTrue(
            templatePicker.addButton.waitForNonExistence(timeout: 5),
            "The picker should close once the journey is added"
        )
    }

    @MainActor
    private func createEmptyJourney(named name: String) {
        journeys.addButton.click()
        XCTAssertTrue(
            journeys.newEmptyMenuItem.waitForExistence(timeout: 5),
            "The add menu should offer an empty journey"
        )
        journeys.newEmptyMenuItem.click()

        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5), "New journey sheet should open")
        newJourneySheet.nameField.click()
        newJourneySheet.nameField.typeText(name)
        newJourneySheet.createButton.click()

        XCTAssertTrue(
            journeys.addStepButton.waitForExistence(timeout: 10),
            "The editor should open on the journey that was just created"
        )
    }

    /// Opens the step sheet from the editor header.
    @MainActor
    private func openStepSheet() {
        XCTAssertTrue(journeys.addStepButton.waitForExistence(timeout: 10), "Add step should be offered")
        journeys.addStepButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForExistence(timeout: 5), "The step sheet should open")
    }

    // MARK: - Interaction helpers

    /// Everything an element says: its label and, when it has one, its value.
    ///
    /// Both are read because which of the two carries a string depends on the control. A `Text`
    /// speaks through its label; a `DSEmptyState`'s flattened leaf arrives as a value; and
    /// `stepSheet.validationMessage` deliberately carries the same sentence in both, so an assertion
    /// over the pair still names *which* of the six rules refused.
    @MainActor
    private func spokenText(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        let value = (element.value as? String) ?? ""
        return element.label + " " + value
    }

    @discardableResult
    @MainActor
    private func waitForSpokenText(
        of element: XCUIElement,
        toContain text: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) { self.spokenText(of: element).contains(text) }
    }

    /// Asserts an element ends up saying `text`, quoting what it actually said when it does not.
    @MainActor
    private func assertSpeaks(
        _ element: XCUIElement,
        contains text: String,
        _ message: String,
        timeout: TimeInterval = 10
    ) {
        XCTAssertTrue(
            waitForSpokenText(of: element, toContain: text, timeout: timeout),
            "\(message) — expected to find \"\(text)\", saw \"\(spokenText(of: element))\""
        )
    }

    /// Whether any part of a `DSEmptyState` speaks `text`.
    ///
    /// The component flattens its leaves, so the heading and the message may arrive as the
    /// container's value rather than as elements of their own; every element carrying the prefix is
    /// asked.
    @MainActor
    private func emptyStateSpeaks(_ text: String, identifierPrefix: String) -> Bool {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
        for index in 0..<query.count where spokenText(of: query.element(boundBy: index)).contains(text) {
            return true
        }
        return false
    }

    /// Replaces a field's contents rather than appending to them.
    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "A field being typed into should be on screen")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// Where an element is and whether the pointer can get to it, as one string for a failure
    /// message. Never an assertion of its own — see the note at the click in
    /// ``testStepsEmptyStateAddsTheFirstStep()``.
    @MainActor
    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "<not in the tree>" }
        return "[\(element.identifier.isEmpty ? element.label : element.identifier) "
            + "frame \(element.frame) hittable \(element.isHittable)]"
    }

    /// Gives the centre pane the request log's height back.
    ///
    /// The same one-click move `EndpointEditorUITests` makes before it reaches for the editor's
    /// fourth card, for the same reason: the drawer takes 220pt off the bottom of the window and the
    /// pane above it is where everything this suite clicks lives. Guarded on the drawer actually
    /// being up, so a caller cannot toggle it *open* and make its own pane shorter.
    @MainActor
    private func hideRequestLogDrawer() {
        guard workspace.toggleDrawerButton.waitForExistence(timeout: 5) else { return }
        guard workspace.drawerEmptyHeading.exists else { return }
        workspace.toggleDrawerButton.click()
        _ = workspace.drawerEmptyHeading.waitForNonExistence(timeout: 3)
    }

    /// A menu item matched the way AppKit actually names one: by **title**.
    ///
    /// `label` is not it. CI printed the element this suite kept catching —
    /// `MenuItem, {{6.0, 224.0}, {251.0, 24.0}}, identifier: '_restartNowRequested:', title:
    /// 'Restart'` — and an XCUITest element description prints `label:` when there is one. There was
    /// none. So `matching(NSPredicate(format: "label == %@", …))` matches *no* menu item in this
    /// app, which is why the scoped query "found nothing" and the loose one found nothing either,
    /// and why `app.menuItems["POST"]` — a subscript, which matches identifier *or* title — has kept
    /// working in `MimicUITestCase.selectMethod` the whole time. All three attributes are asked for
    /// here so neither spelling can be the one that decides.
    private func menuItemTitled(_ option: String) -> NSPredicate {
        NSPredicate(
            format: "identifier == %@ OR title == %@ OR label == %@",
            option, option, option
        )
    }

    /// One option of an open pop-up menu — the *picker's* option, never the menu bar's.
    ///
    /// **Where an open pop-up's menu really lives: app-wide, beside the menu bar's, not under the
    /// pop-up button.** Scoping the query to `picker.descendants` was a guess and it was wrong; the
    /// scoped branch is kept only because a match under the button cannot possibly be a menu-bar
    /// item, and it costs one query when it misses.
    ///
    /// Which makes disambiguation the whole job, because the menu bar's items are in the tree
    /// whether or not their menu is open. "Restart" is the on-completion picker's second option and
    /// also the title of the Apple menu's `_restartNowRequested:` item. **Hittability is what
    /// separates them**, and it is evidence rather than theory in both directions: that Apple item
    /// failed a click with "Not hittable" while its menu was closed, and `selectMethod` clicks the
    /// method pop-up's own items successfully on every run of the request-log suite. A non-hittable
    /// homonym is therefore never returned — clicking the Apple menu's Restart is not a failure a
    /// suite recovers from.
    @MainActor
    private func openMenuItem(titled option: String, in picker: XCUIElement) -> XCUIElement? {
        let scoped = picker.descendants(matching: .menuItem)
            .matching(menuItemTitled(option))
            .firstMatch
        if scoped.exists, scoped.isHittable { return scoped }

        let loose = app.menuItems.matching(menuItemTitled(option))
        for index in 0..<loose.count {
            let candidate = loose.element(boundBy: index)
            if candidate.exists, candidate.isHittable { return candidate }
        }
        return nil
    }

    /// What the tree says about the menus on screen, for a failure that has to name what it saw.
    ///
    /// Bounded: the menu bar alone contributes a few hundred items, and every attribute read is a
    /// query. Only the hittable ones are described, because those are the open menu's — the same
    /// discriminator ``openMenuItem(titled:in:)`` selects on, so a failure shows exactly the set
    /// that was searched.
    @MainActor
    private func openMenuDescription() -> String {
        let items = app.menuItems
        let total = items.count
        var described: [String] = []
        for index in 0..<min(total, 60) where described.count < 12 {
            let item = items.element(boundBy: index)
            guard item.exists, item.isHittable else { continue }
            described.append("\"\(item.title)\"/\"\(item.label)\"")
        }
        let list = described.isEmpty ? "none of them hittable" : described.joined(separator: ", ")
        return "\(app.menus.count) menus and \(total) menu items in the tree; open ones: \(list)"
    }

    /// The characters that pick `option` out of an open menu by typing.
    ///
    /// The first word only. An open `NSMenu` matches what has been typed against item titles as a
    /// prefix, and a **space activates whatever is highlighted** — so typing "Strict sequence" whole
    /// would commit on the space and type "sequence" into whatever is behind the menu. Every option
    /// this suite picks is uniquely identified by its first word within its own menu ("Ordered" /
    /// "Strict", "Stop" / "Restart", "Fall" / "404", and the HTTP methods, where "PO" already
    /// separates POST from PUT and PATCH).
    private func typeSelectPrefix(of option: String) -> String {
        guard let firstWord = option.split(separator: " ").first else { return option }
        return String(firstWord)
    }

    /// Opens a pop-up picker, chooses one of its options, and proves the choice took.
    ///
    /// A SwiftUI `Picker` realizes as a pop-up button, so the menu has to be opened before its items
    /// can be clicked — the same reason `MimicUITestCase.selectMethod` clicks before it queries.
    ///
    /// The assertion is on the **picker's own value afterwards**, not on having found something to
    /// click. That is the fact each caller is here for — the journey remembers the choice — and it
    /// holds however the option was reached, which is what lets the keyboard stand in when the tree
    /// will not name the menu: an open menu selects by typed prefix and commits on Return, no
    /// element lookup involved. Typing is safe in both places this is called from because neither
    /// has a default button armed: the step sheet's save stays disabled until a path is typed, and
    /// the behaviour band is in the main window, which has none.
    @MainActor
    private func choose(_ option: String, in picker: XCUIElement, _ what: String) {
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "\(what) should be on screen")
        guard !spokenText(of: picker).contains(option) else { return }

        picker.click()

        var item: XCUIElement?
        _ = UITestApp.waitUntil(timeout: 5) {
            item = self.openMenuItem(titled: option, in: picker)
            return item != nil
        }
        if let item {
            item.click()
        } else {
            app.typeText(typeSelectPrefix(of: option))
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        }

        XCTAssertTrue(
            waitForSpokenText(of: picker, toContain: option, timeout: 5),
            "\(what) should offer \"\(option)\" and be set to it — the picker reads "
                + "\"\(spokenText(of: picker))\", and \(openMenuDescription())"
        )
    }

    /// Picks one segment of the step sheet's outcome control.
    @MainActor
    private func selectOutcome(_ title: String) {
        let scoped = stepSheet.outcomePicker.descendants(matching: .radioButton)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
        let loose = app.radioButtons[title].firstMatch
        XCTAssertTrue(
            UITestApp.waitForAny([scoped, loose], timeout: 5),
            "The outcome control should offer \"\(title)\""
        )
        (scoped.exists ? scoped : loose).click()
    }

    /// A context-menu item, preferring its identifier and falling back to its title.
    ///
    /// Both are waited on together rather than one after the other: a menu item's identifier
    /// survives only when SwiftUI does not flatten the item, and waiting out the identifier's whole
    /// timeout first would spend it on every call in a suite where the title is what answers.
    @MainActor
    private func menuItem(_ identifier: String, title: String, timeout: TimeInterval = 5) -> XCUIElement {
        let byIdentifier = app.menuItems[identifier].firstMatch
        let byTitle = app.menuItems[title].firstMatch
        XCTAssertTrue(
            UITestApp.waitForAny([byIdentifier, byTitle], timeout: timeout),
            "The context menu should offer \"\(title)\""
        )
        return byIdentifier.exists ? byIdentifier : byTitle
    }

    /// Asserts a context-menu item is *not* offered — both ways it could be named.
    @MainActor
    private func assertNoMenuItem(_ identifier: String, title: String, _ message: String) {
        XCTAssertFalse(app.menuItems[identifier].firstMatch.exists, message)
        XCTAssertFalse(app.menuItems[title].firstMatch.exists, message)
    }

    @MainActor
    private func dismissMenu(waitingFor title: String) {
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(
            app.menuItems[title].firstMatch.waitForNonExistence(timeout: 5),
            "The context menu should close on Escape"
        )
    }

    /// Waits for the previous context menu to have gone before another is opened.
    ///
    /// Only ever a guard for the *negative* assertions: "Move up is not offered on the first step"
    /// is a claim about an empty query, and a menu item left in the tree from the menu before it
    /// would make that claim false for a reason that has nothing to do with the rule under test.
    @MainActor
    private func waitForClosedMenu(itemTitled title: String) {
        XCTAssertTrue(
            app.menuItems[title].firstMatch.waitForNonExistence(timeout: 5),
            "The previous context menu should have closed before the next one opens"
        )
    }

    /// Everything the sidebar says about the run: the strip's composed label, plus the name and
    /// progress leaves when those kept identifiers of their own through the strip's `.contain`.
    ///
    /// Read together rather than one or the other, because which of them survives is a property of
    /// how SwiftUI collapsed that subtree — the fact under test is that the sidebar says where the
    /// run is, not which element ends up saying it.
    @MainActor
    private func sidebarRunText() -> String {
        [
            spokenText(of: journeys.runStrip),
            spokenText(of: journeys.runStripName),
            spokenText(of: journeys.runStripProgress),
        ].joined(separator: " ")
    }

    // MARK: - 1. The editor's behaviour band  (JRNEDIT)

    /// Every control in the "Behavior" band, changed and then read back after the selection has
    /// moved away and returned.
    ///
    /// The round trip is the point. Each picker is bound to `appState.updateJourney`, so a control
    /// that only changed its own `@State` would still read back correctly while the journey it is
    /// supposed to describe went unedited — selecting another journey and coming back is what makes
    /// the assertion about the document rather than about the popup.
    @MainActor
    func testBehaviourControlsChangeTheJourneyAndSurviveReselection() throws {
        launchWithProject()
        showJourneysNavigator()

        createEmptyJourney(named: "Scratch flow")
        addTemplate("retry-after-failure", activate: false)

        XCTAssertTrue(
            journeys.editorName.waitForExistence(timeout: 10),
            "The template journey should be open"
        )
        assertSpeaks(
            journeys.editorName,
            contains: "Retry after failure",
            "The editor header should name the journey it is editing"
        )

        // JRNEDIT-03 — the template's own summary, beside the name.
        assertSpeaks(
            journeys.editorSummary,
            contains: "Login succeeds, the first account load fails, the retry succeeds.",
            "The editor should show the journey's one-line summary"
        )

        // JRNEDIT-05/06/07 — the three pickers.
        assertSpeaks(
            journeys.matchModePicker,
            contains: "Ordered per route",
            "Match mode should start on the default"
        )
        choose("Strict sequence", in: journeys.matchModePicker, "The match mode picker")
        choose("Restart", in: journeys.completionPicker, "The on-completion picker")
        choose("404", in: journeys.unmatchedPicker, "The unscripted-requests picker")

        // JRNEDIT-08 — the checkbox.
        XCTAssertTrue(
            journeys.autoAdvanceToggle.waitForExistence(timeout: 5),
            "Auto-advance should be offered"
        )
        XCTAssertEqual(journeys.autoAdvanceToggle.value as? Int, 0, "Auto-advance should start off")
        journeys.autoAdvanceToggle.click()
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { self.journeys.autoAdvanceToggle.value as? Int == 1 },
            "Clicking auto-advance should turn it on"
        )

        // Away…
        let scratchRow = journeys.row(named: "Scratch flow")
        XCTAssertTrue(scratchRow.waitForExistence(timeout: 5), "Both journeys should be listed")
        scratchRow.click()

        // JRNEDIT-09 — a journey with no steps explains itself instead of showing an empty list.
        XCTAssertTrue(
            journeys.stepsEmptyState.waitForExistence(timeout: 10),
            "A journey with no steps should show the steps empty state"
        )
        XCTAssertTrue(
            emptyStateSpeaks("No steps yet", identifierPrefix: "ds.empty.journeyEditor.steps"),
            "The steps empty state should say there are no steps yet"
        )

        // …and back.
        let templateRow = journeys.row(named: "Retry after failure")
        XCTAssertTrue(templateRow.waitForExistence(timeout: 5), "The template journey should still be listed")
        templateRow.click()
        assertSpeaks(
            journeys.editorName,
            contains: "Retry after failure",
            "Clicking the row should reopen the template journey"
        )

        assertSpeaks(
            journeys.matchModePicker,
            contains: "Strict sequence",
            "The match mode should have been written to the journey, not to the picker"
        )
        assertSpeaks(
            journeys.completionPicker,
            contains: "Restart",
            "The completion behaviour should have been written to the journey"
        )
        assertSpeaks(
            journeys.unmatchedPicker,
            contains: "404",
            "The unscripted-request behaviour should have been written to the journey"
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { self.journeys.autoAdvanceToggle.value as? Int == 1 },
            "Auto-advance should still be on after the selection moved away and returned"
        )
    }

    // MARK: - 2. The steps empty state  (JRNEDIT-09/10, JRNRUN-02)

    /// The second of the two controls that open `JourneyStepSheet` — the one inside the empty state,
    /// which no test has ever clicked because both used to be spelled the same way.
    @MainActor
    func testStepsEmptyStateAddsTheFirstStep() throws {
        launchWithProject()
        showJourneysNavigator()
        createEmptyJourney(named: "Hand written flow")

        // The drawer's height, given back before anything below is reached for.
        //
        // `JourneyEditorView` lets the step area — and only the step area — compress to nothing, so
        // everything above it keeps its space and the empty state takes what is left. On a CI-sized
        // window with the request log open, what is left is less than the ~187pt a `DSEmptyState`
        // draws, and a `VStack` given less than it needs centres the overflow: the call to action,
        // which is the last thing in that stack, is drawn below the pane. That is both ways this
        // step has failed — first as "the step sheet should open", a click that landed on the
        // message text, then as a call to action that was in the tree and not hittable.
        //
        // There is nothing to scroll here: the empty state is not in a scroll view. The drawer is
        // the only room available, and taking it is what `EndpointEditorUITests` does for the same
        // class of failure in the editor's fourth card.
        hideRequestLogDrawer()

        XCTAssertTrue(
            journeys.stepsEmptyState.waitForExistence(timeout: 10),
            "A new journey should explain that it has no steps yet"
        )
        XCTAssertTrue(
            emptyStateSpeaks(
                "Add the requests this flow makes",
                identifierPrefix: "ds.empty.journeyEditor.steps"
            ),
            "The steps empty state should explain what a step is for"
        )

        // JRNRUN-02 — a journey with nothing to serve cannot be activated.
        XCTAssertTrue(journeys.activateButton.waitForExistence(timeout: 5), "Activate should be present")
        XCTAssertFalse(
            journeys.activateButton.isEnabled,
            "Activating a journey with no steps would serve nothing, so it should be refused"
        )

        // JRNEDIT-10 — the empty state's own call to action.
        XCTAssertTrue(
            journeys.stepsEmptyStateAddButton.waitForExistence(timeout: 5),
            "The steps empty state should offer to add the first step"
        )
        journeys.stepsEmptyStateAddButton.click()

        // The assertion is that clicking it opens the sheet, and the geometry rides along in the
        // message rather than in an assertion of its own.
        //
        // `isHittable` was that assertion last round and it is not a property this window's controls
        // dependably carry: `WorkspaceShellUITests.testGroupCrumbJumpsToAnotherGroup` clicks the
        // endpoint editor's group tag field, types into it and watches the jump bar answer, in the
        // same CI run in which `EndpointEditorUITests` reported that identical field "not reachable
        // in the editor pane". A gate that a working control fails is not a gate. What it was
        // written to catch — a click that lands on something else — is caught here directly, by the
        // sheet that does not open, with the frames printed beside it so the next reader can tell a
        // squeezed pane from a mis-targeted query.
        XCTAssertTrue(
            stepSheet.pathField.waitForExistence(timeout: 5),
            "The step sheet should open when the empty state's call to action is clicked — "
                + "the call to action is \(describe(journeys.stepsEmptyStateAddButton)) "
                + "inside \(describe(journeys.stepsEmptyState))"
        )
        assertSpeaks(stepSheet.title, contains: "Add step", "The sheet should be headed for adding")

        stepSheet.pathField.click()
        stepSheet.pathField.typeText("/orders")
        stepSheet.saveButton.click()

        XCTAssertTrue(journeys.step(at: 0).waitForExistence(timeout: 5), "The step should join the sequence")
        assertSpeaks(
            journeys.step(at: 0),
            contains: "/orders",
            "The new step should show the route it answers"
        )
        assertSpeaks(
            journeys.step(at: 0),
            contains: "responds 200",
            "A step saved with the default status should respond with it"
        )
        XCTAssertTrue(
            journeys.stepsEmptyState.waitForNonExistence(timeout: 5),
            "The empty state should give way to the step list"
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { self.journeys.activateButton.isEnabled },
            "A journey with a step to serve should be activatable"
        )
    }

    // MARK: - 3. The step sheet's gate and its cancel  (JRNSTEP-01/04/20/21)

    @MainActor
    func testStepSheetKeepsSaveDisabledUntilAPathIsTypedAndCancelsCleanly() throws {
        launchWithProject()
        showJourneysNavigator()
        createEmptyJourney(named: "Gatekeeping")
        openStepSheet()

        assertSpeaks(stepSheet.title, contains: "Add step", "The sheet should be headed for adding")
        XCTAssertFalse(
            stepSheet.saveButton.isEnabled,
            "A step with no path has nothing to match, so saving should be refused outright"
        )

        // JRNSTEP-01 — the name is optional, so naming the step must not unlock the save.
        stepSheet.nameField.click()
        stepSheet.nameField.typeText("Loads the dashboard")
        XCTAssertFalse(
            stepSheet.saveButton.isEnabled,
            "A name is not a route — the save should still be refused"
        )

        stepSheet.pathField.click()
        stepSheet.pathField.typeText("/dashboard")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { self.stepSheet.saveButton.isEnabled },
            "A path is all a step needs, so the save should now be offered"
        )

        // JRNSTEP-20 — cancelling leaves the journey as it was.
        stepSheet.cancelButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForNonExistence(timeout: 5), "Cancel should dismiss the sheet")
        XCTAssertTrue(
            journeys.stepsEmptyState.waitForExistence(timeout: 5),
            "Cancelling should add nothing, so the journey should still have no steps"
        )
        XCTAssertFalse(journeys.step(at: 0).exists, "No step should have been created")
    }

    // MARK: - 4. Six refusals, each with its own message  (JRNSTEP-05/06/08/13/14/16/18/19)

    /// Every guard in `JourneyStepSheet.commit()`, driven in the order the function checks them, with
    /// the specific complaint asserted each time.
    ///
    /// One sheet rather than six tests because the assertion that matters is *which* rule refused —
    /// six rules speak through one `stepSheet.validationMessage`, so a test that only proved
    /// "something was rejected" would pass just as happily on the wrong complaint. The value the view
    /// now carries is the same sentence as the label, so reading either names the rule.
    @MainActor
    func testStepSheetNamesTheRuleThatRefusedEachTime() throws {
        launchWithProject()
        showJourneysNavigator()
        createEmptyJourney(named: "Validation")
        openStepSheet()

        // JRNSTEP-05 — the path.
        stepSheet.pathField.click()
        stepSheet.pathField.typeText("orders")
        stepSheet.saveButton.click()
        assertSpeaks(
            stepSheet.validationMessage,
            contains: "Path must start with '/'",
            "A path with no leading slash should be refused by name"
        )

        // JRNSTEP-06 — editing the offending field clears its complaint.
        replaceText(in: stepSheet.pathField, with: "/orders")
        XCTAssertTrue(
            stepSheet.validationMessage.waitForNonExistence(timeout: 5),
            "Fixing the path should retract the complaint about it"
        )

        // JRNSTEP-08 — the status code. Checked after the delay and the serve count, so both are
        // left at their valid defaults here.
        replaceText(in: stepSheet.statusField, with: "999")
        stepSheet.saveButton.click()
        assertSpeaks(
            stepSheet.validationMessage,
            contains: "Status code must be between 200 and 599.",
            "An out-of-range status should be refused by name"
        )

        // JRNSTEP-16 — the delay. This is the coercion regression: "abc" used to become a step that
        // answered instantly, with nothing said.
        replaceText(in: stepSheet.statusField, with: "201")
        replaceText(in: stepSheet.delayField, with: "abc")
        stepSheet.saveButton.click()
        assertSpeaks(
            stepSheet.validationMessage,
            contains: "Delay must be a whole number of milliseconds, zero or more.",
            "A non-numeric delay should be refused by name rather than coerced to zero"
        )

        // JRNSTEP-18 — the serve count. "0" used to be silently raised to 1.
        replaceText(in: stepSheet.delayField, with: "0")
        replaceText(in: stepSheet.repeatField, with: "0")
        stepSheet.saveButton.click()
        assertSpeaks(
            stepSheet.validationMessage,
            contains: "Serve count must be 1 or more.",
            "A serve count of zero should be refused by name"
        )

        // JRNSTEP-13/14 — the timeout hold, on the outcome that owns it.
        replaceText(in: stepSheet.repeatField, with: "1")
        selectOutcome("Time out")
        XCTAssertTrue(
            stepSheet.holdField.waitForExistence(timeout: 5),
            "Timing out should ask how long to hold"
        )
        XCTAssertTrue(
            stepSheet.timeoutHint.waitForExistence(timeout: 5),
            "The hold should be explained beside the field"
        )
        replaceText(in: stepSheet.holdField, with: "abc")
        stepSheet.saveButton.click()
        assertSpeaks(
            stepSheet.validationMessage,
            contains: "Hold duration must be zero or greater.",
            "A non-numeric hold should be refused by name"
        )

        // JRNSTEP-19 — and with every field valid, the step lands.
        replaceText(in: stepSheet.holdField, with: "750")
        stepSheet.saveButton.click()
        XCTAssertTrue(
            stepSheet.pathField.waitForNonExistence(timeout: 5),
            "The sheet should close on a good save"
        )
        XCTAssertTrue(journeys.step(at: 0).waitForExistence(timeout: 5), "The step should join the sequence")
        assertSpeaks(
            journeys.step(at: 0),
            contains: "fails with timeout 750ms",
            "The saved step should carry the hold that was typed"
        )
    }

    // MARK: - 5. Authoring a respond step in full  (JRNSTEP-01/02/09/10/11/19)

    @MainActor
    func testStepSheetAuthorsARespondStepWithMethodHeadersAndBody() throws {
        launchWithProject()
        showJourneysNavigator()
        createEmptyJourney(named: "Payments")
        openStepSheet()

        stepSheet.nameField.click()
        stepSheet.nameField.typeText("Charge declined")

        // JRNSTEP-02 — every step before this one was a GET by default.
        choose("POST", in: stepSheet.methodPicker, "The step's method picker")

        stepSheet.pathField.click()
        stepSheet.pathField.typeText("/payments")
        replaceText(in: stepSheet.statusField, with: "402")

        // JRNSTEP-10 — the hint that says how to get a second line, which is not guessable.
        XCTAssertTrue(
            stepSheet.headersHint.waitForExistence(timeout: 5),
            "The headers field should explain how to add another line"
        )
        assertSpeaks(
            stepSheet.headersHint,
            contains: "One per line",
            "The hint should say headers go one per line"
        )

        // JRNSTEP-09 / JRNSTEP-11.
        stepSheet.headersField.click()
        stepSheet.headersField.typeText("Retry-After: 30")
        stepSheet.bodyField.click()
        stepSheet.bodyField.typeText("{\"error\":\"card_declined\"}")

        stepSheet.saveButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForNonExistence(timeout: 5), "The sheet should close on save")

        XCTAssertTrue(journeys.step(at: 0).waitForExistence(timeout: 5), "The step should join the sequence")
        assertSpeaks(
            journeys.step(at: 0),
            contains: "POST",
            "The step should keep the method that was picked"
        )
        assertSpeaks(journeys.step(at: 0), contains: "/payments", "The step should keep its route")
        assertSpeaks(journeys.step(at: 0), contains: "responds 402", "The step should keep its status code")
    }

    // MARK: - 6. The outcome control  (JRNSTEP-12/13)

    /// A step either answers or fails at the transport level, and the form shows only the fields that
    /// apply — so switching the outcome is what makes those fields appear and disappear.
    @MainActor
    func testOutcomePickerSwapsTheFieldsAndAuthorsADroppedConnection() throws {
        launchWithProject()
        showJourneysNavigator()
        createEmptyJourney(named: "Transport failures")
        openStepSheet()

        XCTAssertTrue(stepSheet.statusField.waitForExistence(timeout: 5), "Respond is the default outcome")

        // JRNSTEP-12.
        selectOutcome("Drop the connection")
        XCTAssertTrue(
            stepSheet.dropHint.waitForExistence(timeout: 5),
            "Dropping the connection should explain what the client sees"
        )
        assertSpeaks(
            stepSheet.dropHint,
            contains: "network failure",
            "The explanation should say the client sees a network failure, not a status code"
        )
        XCTAssertTrue(
            stepSheet.statusField.waitForNonExistence(timeout: 5),
            "A dropped connection has no status code to set"
        )

        // JRNSTEP-13 — and the third outcome brings its own field.
        selectOutcome("Time out")
        XCTAssertTrue(stepSheet.holdField.waitForExistence(timeout: 5), "Timing out should ask for a hold")
        XCTAssertFalse(stepSheet.statusField.exists, "A timeout has no status code either")

        selectOutcome("Respond")
        XCTAssertTrue(
            stepSheet.statusField.waitForExistence(timeout: 5),
            "Coming back to Respond should bring the status code back"
        )

        selectOutcome("Drop the connection")
        stepSheet.pathField.click()
        stepSheet.pathField.typeText("/stream")
        stepSheet.saveButton.click()

        XCTAssertTrue(journeys.step(at: 0).waitForExistence(timeout: 5), "The step should join the sequence")
        assertSpeaks(
            journeys.step(at: 0),
            contains: "fails with drop",
            "The saved step should be the transport failure that was chosen"
        )
    }

    // MARK: - 7. Editing an existing step  (JRNSTEP-21/22, JRNORD-01/03)

    /// `loadExistingStep()` has never run in a UI test: every test so far has added a step and
    /// stopped. This reopens one, reads what the sheet loaded, changes it, and saves in place.
    @MainActor
    func testEditingAStepLoadsItsValuesAndSavesInPlace() throws {
        launchWithProject()
        showJourneysNavigator()
        createEmptyJourney(named: "Editing")
        openStepSheet()

        stepSheet.nameField.click()
        stepSheet.nameField.typeText("Charge declined")
        choose("POST", in: stepSheet.methodPicker, "The step's method picker")
        stepSheet.pathField.click()
        stepSheet.pathField.typeText("/payments")
        replaceText(in: stepSheet.statusField, with: "402")
        stepSheet.saveButton.click()
        XCTAssertTrue(journeys.step(at: 0).waitForExistence(timeout: 5), "The step should join the sequence")

        // JRNORD-01 — the row is the way back into the sheet.
        journeys.step(at: 0).click()
        XCTAssertTrue(stepSheet.pathField.waitForExistence(timeout: 5), "Clicking a step should reopen it")

        // JRNSTEP-21 — the sheet is headed differently and arrives populated.
        assertSpeaks(
            stepSheet.title,
            contains: "Edit step",
            "Reopening a step should head the sheet for editing"
        )
        assertSpeaks(
            stepSheet.saveButton,
            contains: "Save step",
            "The confirm action should be a save, not an add"
        )
        assertSpeaks(stepSheet.nameField, contains: "Charge declined", "The step's name should be loaded")
        assertSpeaks(stepSheet.pathField, contains: "/payments", "The step's path should be loaded")
        assertSpeaks(stepSheet.statusField, contains: "402", "The step's status code should be loaded")
        assertSpeaks(stepSheet.methodPicker, contains: "POST", "The step's method should be loaded")

        // JRNSTEP-22 — the edit replaces the step rather than appending a second one.
        replaceText(in: stepSheet.pathField, with: "/payments/retry")
        stepSheet.saveButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForNonExistence(timeout: 5), "The sheet should close on save")

        assertSpeaks(
            journeys.step(at: 0),
            contains: "/payments/retry",
            "The edited step's row should update in place"
        )
        XCTAssertFalse(journeys.step(at: 1).exists, "Editing a step should not add a second one")

        // JRNORD-03 — the context menu is the second way into the same sheet, and it has to load the
        // step the menu was opened on rather than a fresh one.
        journeys.step(at: 0).rightClick()
        menuItem("journeyEditor.step.contextMenu.edit", title: "Edit step\u{2026}").click()
        XCTAssertTrue(stepSheet.pathField.waitForExistence(timeout: 5), "Edit step… should open the sheet")
        assertSpeaks(stepSheet.title, contains: "Edit step", "The menu should open the sheet for editing")
        assertSpeaks(
            stepSheet.pathField,
            contains: "/payments/retry",
            "The sheet should load the step the menu was opened on, with the edit already in it"
        )
        stepSheet.cancelButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForNonExistence(timeout: 5), "Cancel should dismiss the sheet")
    }

    // MARK: - 8. The step context menu  (JRNORD-02/04/05/06)

    /// Reordering and removing, and the two items that are conditional on position.
    ///
    /// `retry-after-failure` is the fixture because its four steps have three distinct routes, so an
    /// order change is legible in the rows' spoken labels rather than inferred from a count.
    @MainActor
    func testStepContextMenuReordersAndRemovesSteps() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("retry-after-failure", activate: false)

        for index in 0..<4 {
            XCTAssertTrue(
                journeys.step(at: index).waitForExistence(timeout: 10),
                "Step \(index) should be listed"
            )
        }
        assertSpeaks(journeys.step(at: 0), contains: "/login", "The template should start with the login")

        // JRNORD-02 — the whole menu, on a step that is neither first nor last.
        journeys.step(at: 1).rightClick()
        _ = menuItem("journeyEditor.step.contextMenu.remove", title: "Remove step")
        _ = menuItem("journeyEditor.step.contextMenu.edit", title: "Edit step\u{2026}")
        _ = menuItem("journeyEditor.step.contextMenu.moveDown", title: "Move down")
        let moveUp = menuItem("journeyEditor.step.contextMenu.moveUp", title: "Move up")

        // JRNORD-04.
        moveUp.click()
        assertSpeaks(
            journeys.step(at: 0),
            contains: "responds 500",
            "Moving the failing call up should put it first"
        )
        assertSpeaks(journeys.step(at: 1), contains: "/login", "The login should have been pushed down")

        // The first step cannot move up — the item is not rendered at all for index 0.
        waitForClosedMenu(itemTitled: "Move up")
        journeys.step(at: 0).rightClick()
        _ = menuItem("journeyEditor.step.contextMenu.remove", title: "Remove step")
        assertNoMenuItem(
            "journeyEditor.step.contextMenu.moveUp",
            title: "Move up",
            "The first step has nowhere to move up to, so the item should not be offered"
        )

        // JRNORD-05 — and back down again, restoring the template's order.
        menuItem("journeyEditor.step.contextMenu.moveDown", title: "Move down").click()
        assertSpeaks(journeys.step(at: 0), contains: "/login", "Moving it back down should restore the order")

        // The last step cannot move down.
        waitForClosedMenu(itemTitled: "Move down")
        journeys.step(at: 3).rightClick()
        _ = menuItem("journeyEditor.step.contextMenu.remove", title: "Remove step")
        assertNoMenuItem(
            "journeyEditor.step.contextMenu.moveDown",
            title: "Move down",
            "The last step has nowhere to move down to, so the item should not be offered"
        )
        dismissMenu(waitingFor: "Remove step")

        // JRNORD-06 — destructive and unconfirmed, which is exactly why it needs covering.
        assertSpeaks(journeys.step(at: 2), contains: "/inbox", "The third step should be the inbox load")
        journeys.step(at: 2).rightClick()
        menuItem("journeyEditor.step.contextMenu.remove", title: "Remove step").click()

        XCTAssertTrue(
            journeys.step(at: 3).waitForNonExistence(timeout: 5),
            "Removing a step should leave the journey one shorter"
        )
        for index in 0..<3 {
            XCTAssertFalse(
                spokenText(of: journeys.step(at: index)).contains("/inbox"),
                "The removed step should be gone from the sequence, not merely renumbered"
            )
        }
    }

    // MARK: - 9. Driving the run from the editor  (JRNRUN)

    /// Restart and Advance, clicked rather than merely found.
    ///
    /// The existing suite asserts these two report `isEnabled` and never presses them, so the cursor
    /// mutations behind them — and the arithmetic in `JourneyRunControls.progressText` — have never
    /// been exercised through the window. This walks a two-step journey to completion and back.
    @MainActor
    func testRunControlsAdvanceToCompletionAndRestart() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("payment-retry", activate: false)

        XCTAssertTrue(journeys.editorName.waitForExistence(timeout: 10), "The journey should be open")

        // JRNRUN-01 — the readout answers "is something overriding my endpoints right now".
        assertSpeaks(
            journeys.runProgressReadout,
            contains: "Not active",
            "Before activation the readout should say the endpoints answer for themselves"
        )
        XCTAssertFalse(journeys.advanceButton.isEnabled, "Advance is meaningless before activation")

        journeys.activateButton.click()
        XCTAssertTrue(
            journeys.deactivateButton.waitForExistence(timeout: 10),
            "Activating should offer to stop"
        )

        // JRNRUN-05 — the arithmetic reaching the window.
        assertSpeaks(
            journeys.runProgressReadout,
            contains: "Step 1 of 2",
            "A fresh run should sit on the first of the journey's two steps"
        )
        assertSpeaks(journeys.runProgressReadout, contains: "0 served", "Nothing has been served yet")

        // JRNRUN-10 — the run is marked in the list you edit.
        assertSpeaks(
            journeys.step(at: 0),
            contains: "current step",
            "The first step should be marked as current"
        )

        // JRNRUN-07.
        journeys.advanceButton.click()
        assertSpeaks(
            journeys.runProgressReadout,
            contains: "Step 2 of 2",
            "Advancing should retire the current step and move the cursor on"
        )
        assertSpeaks(
            journeys.step(at: 0),
            contains: "already served",
            "The retired step should read as spent"
        )
        assertSpeaks(journeys.step(at: 1), contains: "current step", "The second step should now be current")

        // JRNRUN-08.
        journeys.advanceButton.click()
        assertSpeaks(
            journeys.runProgressReadout,
            contains: "Complete",
            "Advancing past the last step should complete the run"
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { !self.journeys.advanceButton.isEnabled },
            "There is nothing left to advance to once the run is complete"
        )

        // JRNRUN-06.
        journeys.restartButton.click()
        assertSpeaks(
            journeys.runProgressReadout,
            contains: "Step 1 of 2",
            "Restarting should rewind the run to its first step"
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { self.journeys.advanceButton.isEnabled },
            "A rewound run can be advanced again"
        )
        assertSpeaks(journeys.step(at: 0), contains: "current step", "The first step should be current again")
        XCTAssertFalse(
            spokenText(of: journeys.step(at: 0)).contains("already served"),
            "A restart should forget that the first step was retired"
        )
    }

    // MARK: - 10. Driving the run from the navigator  (JRNBAR, JRN-07/08)

    /// The sidebar's run strip, which exists only while a journey is answering.
    ///
    /// Every query into the strip is scoped to it. `journeys.deactivateButton` and
    /// `JourneyRunControls`' own button both answer to the label "Deactivate journey", and with a
    /// template journey selected they are both on screen — an unscoped query would resolve to
    /// whichever AppKit happened to enumerate first, which is a coin toss the test would pass half
    /// the time. The final assertions prove the scoping picked the right one: the strip goes away
    /// *and* the editor swings back to offering Activate.
    @MainActor
    func testNavigatorRunStripDrivesTheRun() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("session-expiry", activate: false)

        let name = "Session expires mid-flow"
        XCTAssertTrue(
            journeys.row(named: name).waitForExistence(timeout: 10),
            "The journey should be listed"
        )
        XCTAssertFalse(journeys.runStrip.exists, "No journey is answering, so there should be no strip")

        // JRN-07 — the row's ring activates without selecting.
        let ring = journeys.activationRing(activateNamed: name)
        XCTAssertTrue(ring.waitForExistence(timeout: 5), "The row should offer its activation ring")
        ring.click()

        // JRNBAR-01/02 — the strip, its journey name and its position.
        XCTAssertTrue(
            journeys.runStrip.waitForExistence(timeout: 10),
            "Activating should raise the run strip"
        )
        assertSpeaks(
            journeys.runStrip,
            contains: "Running journey \(name)",
            "The strip should name the journey that is answering"
        )
        // The leaf keeps its identifier only when SwiftUI does not flatten it through the strip's
        // `.contain`; either it or the strip's composed label has to carry the position, and
        // `sidebarRunText()` reads both so the assertion is about the sidebar rather than about
        // which of the two the tree happened to keep.
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { self.sidebarRunText().contains("Step 1 of 5") },
            "The strip should report where the run is; saw \"\(self.sidebarRunText())\""
        )

        // JRNBAR-04.
        journeys.runStripAdvanceButton.click()
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { self.sidebarRunText().contains("Step 2 of 5") },
            "Advancing from the sidebar should move the run on; saw \"\(self.sidebarRunText())\""
        )

        // JRNBAR-03.
        journeys.runStripRestartButton.click()
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { self.sidebarRunText().contains("Step 1 of 5") },
            "Restarting from the sidebar should rewind the run; saw \"\(self.sidebarRunText())\""
        )

        // JRN-08 — the same ring, with its label flipped, ends the run.
        let stopRing = journeys.activationRing(deactivateNamed: name)
        XCTAssertTrue(stopRing.waitForExistence(timeout: 5), "The ring should now offer to deactivate")
        stopRing.click()
        XCTAssertTrue(
            journeys.runStrip.waitForNonExistence(timeout: 10),
            "Deactivating from the row should take the strip away"
        )

        // JRNBAR-05 — and the strip's own way out.
        journeys.activationRing(activateNamed: name).click()
        XCTAssertTrue(
            journeys.runStrip.waitForExistence(timeout: 10),
            "The journey should be answering again"
        )
        journeys.runStripDeactivateButton.click()
        XCTAssertTrue(
            journeys.runStrip.waitForNonExistence(timeout: 10),
            "The strip's stop control should end the run"
        )
        XCTAssertTrue(
            journeys.activateButton.waitForExistence(timeout: 10),
            "The editor should offer to activate again — which is how we know the strip's button was "
                + "the one that was clicked, and not the editor's identically labelled one"
        )
    }

    // MARK: - 11. Duplicating a journey  (JRN-09, JRNDUP)

    @MainActor
    func testDuplicateJourneyFromTheRowContextMenu() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("payment-retry", activate: false)

        let name = "Payment succeeds on retry"
        let row = journeys.row(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The journey should be listed")
        assertSpeaks(row, contains: "2 steps", "The row should say how much journey it is")
        assertSpeaks(row, contains: "not active", "Selecting a journey is not activating it")

        // JRN-09 — the whole row menu.
        row.rightClick()
        _ = menuItem("journeys.contextMenu.toggleActivation", title: "Activate")
        _ = menuItem("journeys.contextMenu.delete", title: "Delete journey\u{2026}")
        let duplicate = menuItem("journeys.contextMenu.duplicate", title: "Duplicate")

        // JRNDUP-01/02.
        duplicate.click()
        let copy = journeys.row(named: "\(name) (Copy)")
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "The copy should be listed beside the original")
        assertSpeaks(copy, contains: "2 steps", "The copy should carry the same steps as the original")
        XCTAssertTrue(journeys.row(named: name).exists, "The original should still be there")
    }

    // MARK: - 12. Deleting a journey  (JRNDEL, JRNEDIT-04)

    /// The confirmation is the point: a journey takes all of its steps with it and `AppState` has no
    /// undo anywhere, so the alert is the only thing between a right-click and losing a flow.
    ///
    /// A SwiftUI `.alert` cannot be given an accessibility identifier, so it is matched as a dialog
    /// by the journey's name in its title and by its buttons' labels — the same way
    /// `DeleteConfirmationPage` matches the welcome window's.
    @MainActor
    func testDeleteJourneyConfirmsFirstAndCanBeCalledOff() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("payment-retry", activate: false)

        let name = "Payment succeeds on retry"
        XCTAssertTrue(journeys.row(named: name).waitForExistence(timeout: 10), "The journey should be listed")

        // JRNDEL-01/02.
        journeys.row(named: name).rightClick()
        menuItem("journeys.contextMenu.delete", title: "Delete journey\u{2026}").click()

        let alert = app.sheets.firstMatch
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(
            UITestApp.waitForAny([alert, dialog], timeout: 5),
            "Deleting a journey should ask before it takes the steps with it"
        )
        let confirmation = alert.exists ? alert : dialog

        // The title is a `String` in `.alert(_:isPresented:)`, so it carries no identifier and it is
        // not even reliably an element: AppKit may realize it as the alert's `messageText`, in which
        // case it arrives as the sheet's own `label` rather than as a static text inside it. And a
        // static text that *is* there keeps its string in `value` as often as in `label`. All three
        // are accepted — the assertion is that the journey is named somewhere in the confirmation,
        // which is the point of the step. `WelcomeProjectUITests` matches the project alert the same
        // way, and matching on `label` alone is what failed here.
        let titleInDialog = confirmation.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", name, name))
            .firstMatch
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 3) {
                titleInDialog.exists || confirmation.label.contains(name)
            },
            "The confirmation should name the journey it is about to delete"
        )

        // The message is the informative text, read the same way and for the same reason.
        let messageInDialog = confirmation.staticTexts
            .matching(NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@",
                "all of its steps",
                "all of its steps"
            ))
            .firstMatch
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 3) {
                messageInDialog.exists || confirmation.label.contains("all of its steps")
            },
            "The confirmation should warn that the steps go with the journey"
        )

        // JRNDEL-03.
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5), "Cancelling should dismiss the alert")
        XCTAssertTrue(journeys.row(named: name).exists, "Cancelling should leave the journey where it was")

        // JRNDEL-04.
        journeys.row(named: name).rightClick()
        menuItem("journeys.contextMenu.delete", title: "Delete journey\u{2026}").click()
        let second = app.sheets.firstMatch
        let secondDialog = app.dialogs.firstMatch
        XCTAssertTrue(
            UITestApp.waitForAny([second, secondDialog], timeout: 5),
            "The confirmation should come up again"
        )
        (second.exists ? second : secondDialog).buttons["Delete"].click()

        XCTAssertTrue(
            journeys.row(named: name).waitForNonExistence(timeout: 10),
            "Confirming should remove the journey"
        )

        // JRNDEL-05 — and with the last journey gone, the navigator explains itself again.
        XCTAssertTrue(
            journeys.emptyStateHeading.waitForExistence(timeout: 10),
            "Deleting the last journey should bring the empty state back"
        )
        // JRNEDIT-04 — the centre pane has nothing left to edit and says so.
        XCTAssertTrue(
            journeys.noJourneySelectionEmptyState.waitForExistence(timeout: 10),
            "With no journey selected the centre pane should explain why it is empty"
        )
    }

    // MARK: - 13. The template shelf  (JRNTMPL-02/08)

    /// Every one of the nine templates, and the cancel that adds none of them.
    ///
    /// The list is 320pt tall and shows roughly four rows, so the shelf is walked with the arrow keys
    /// rather than scrolled by a guessed delta: selection moves, AppKit scrolls the selected row into
    /// view, and each row is asserted as it arrives.
    @MainActor
    func testTemplateShelfListsEveryTemplateAndCancels() throws {
        launchWithProject()
        showJourneysNavigator()

        journeys.addButton.click()
        XCTAssertTrue(
            journeys.templateMenuItem.waitForExistence(timeout: 5),
            "The add menu should offer templates"
        )
        journeys.templateMenuItem.click()
        XCTAssertTrue(
            templatePicker.addButton.waitForExistence(timeout: 5),
            "The template picker should open"
        )

        // Title and step count, which is the row's whole content — the shelf is meant to be readable
        // before anything is added.
        let shelf: [(id: String, title: String, steps: String)] = [
            ("retry-after-failure", "Retry after failure", "4 steps"),
            ("payment-retry", "Payment succeeds on retry", "2 steps"),
            ("session-expiry", "Session expires mid-flow", "5 steps"),
            ("mfa-challenge", "MFA required after login", "3 steps"),
            ("maintenance-window", "Backend maintenance mode", "2 steps"),
            ("progressive-loading", "Progressive loading states", "3 steps"),
            ("offline-to-online", "Offline then online", "3 steps"),
            ("feature-flag-rollout", "Feature flag variations", "2 steps"),
            ("edge-case-responses", "Edge-case API responses", "4 steps"),
        ]

        let first = templatePicker.template(shelf[0].id)
        XCTAssertTrue(first.waitForExistence(timeout: 5), "The shelf should open on its first template")
        first.click()

        for (index, template) in shelf.enumerated() {
            if index > 0 {
                app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
            }
            let row = templatePicker.template(template.id)
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "Template \(template.id) should be reachable on the shelf"
            )
            assertSpeaks(row, contains: template.title, "The \(template.id) row should carry its title")
            assertSpeaks(
                row,
                contains: template.steps,
                "The \(template.id) row should say how many steps it is"
            )
        }

        // JRNTMPL-08.
        templatePicker.cancelButton.click()
        XCTAssertTrue(
            templatePicker.addButton.waitForNonExistence(timeout: 5),
            "Cancel should dismiss the picker"
        )
        XCTAssertTrue(
            journeys.emptyStateHeading.waitForExistence(timeout: 5),
            "Cancelling should add nothing, so the project should still have no journeys"
        )
    }

    // MARK: - 14. "Activate once added"  (JRNTMPL-04/05)

    @MainActor
    func testTemplateActivateToggleDecidesWhetherTheJourneyStartsAnswering() throws {
        launchWithProject()
        showJourneysNavigator()

        // JRNTMPL-04 — added inert.
        addTemplate("mfa-challenge", activate: false)
        XCTAssertTrue(
            journeys.editorName.waitForExistence(timeout: 10),
            "The journey should open in the editor"
        )
        XCTAssertTrue(
            journeys.activateButton.waitForExistence(timeout: 5),
            "An inert journey offers to be activated"
        )
        XCTAssertFalse(journeys.activeBadge.exists, "An inert journey should not read as active")
        XCTAssertFalse(journeys.runStrip.exists, "Nothing is answering, so there should be no run strip")
        assertSpeaks(
            journeys.row(named: "MFA required after login"),
            contains: "not active",
            "The row should say the journey is not answering"
        )

        // JRNTMPL-05 — added answering.
        addTemplate("payment-retry", activate: true)
        XCTAssertTrue(
            journeys.activeBadge.waitForExistence(timeout: 10),
            "A journey added with the toggle on should be answering immediately"
        )
        XCTAssertTrue(
            journeys.deactivateButton.waitForExistence(timeout: 10),
            "The editor should offer to stop it"
        )
        XCTAssertTrue(
            journeys.runStrip.waitForExistence(timeout: 10),
            "The navigator should raise its run strip"
        )
        assertSpeaks(
            journeys.runStrip,
            contains: "Running journey Payment succeeds on retry",
            "The strip should name the journey that is answering"
        )
        assertSpeaks(
            journeys.row(named: "MFA required after login"),
            contains: "not active",
            "Activating one journey should not activate the other"
        )
    }

    // MARK: - 15. The new-journey sheet  (JRNNEW)

    @MainActor
    func testNewJourneySheetExplainsItselfAndCreatesOnReturn() throws {
        launchWithProject()
        showJourneysNavigator()

        journeys.addButton.click()
        XCTAssertTrue(
            journeys.newEmptyMenuItem.waitForExistence(timeout: 5),
            "The add menu should offer an empty journey"
        )
        journeys.newEmptyMenuItem.click()
        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5), "The sheet should open")

        // JRNNEW-02.
        assertSpeaks(newJourneySheet.title, contains: "New journey", "The sheet should say what it is")
        assertSpeaks(
            newJourneySheet.explanation,
            contains: "ordered sequence of responses",
            "The sheet should explain what a journey is before asking for a name"
        )

        // JRNNEW-05 — an unnamed journey cannot be created.
        XCTAssertFalse(newJourneySheet.createButton.isEnabled, "A journey needs a name")

        // JRNNEW-07 — and the sheet can be walked away from.
        newJourneySheet.cancelButton.click()
        XCTAssertTrue(
            newJourneySheet.nameField.waitForNonExistence(timeout: 5),
            "Cancel should dismiss the sheet"
        )
        XCTAssertTrue(
            journeys.emptyStateHeading.waitForExistence(timeout: 5),
            "Cancelling should create nothing"
        )

        // JRNNEW-06 — Return in the name field is the keyboard path to the same result.
        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5), "The add menu should reopen")
        journeys.newEmptyMenuItem.click()
        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5), "The sheet should reopen")
        newJourneySheet.nameField.click()
        newJourneySheet.nameField.typeText("Typed and returned")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { self.newJourneySheet.createButton.isEnabled },
            "A named journey should be creatable"
        )
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        XCTAssertTrue(
            newJourneySheet.nameField.waitForNonExistence(timeout: 5),
            "Return should commit the sheet"
        )
        XCTAssertTrue(
            journeys.row(named: "Typed and returned").waitForExistence(timeout: 10),
            "The journey should be listed under the name that was typed"
        )
        assertSpeaks(
            journeys.editorName,
            contains: "Typed and returned",
            "The new journey should open in the editor"
        )
    }
}
