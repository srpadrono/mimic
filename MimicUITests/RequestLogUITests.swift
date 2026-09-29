import AppKit
import Foundation
import Network
import XCTest

/// The request log's own suite: sorting, filtering, selection, the row context menu, the request
/// detail beside the log, and the endpoint inspector's Traffic section.
///
/// It sits beside `MimicUITests` rather than inside it because that file is already 1,800 lines and
/// its page objects are file-scope — so this suite **reuses** `RequestLogDrawerPage`,
/// `RequestDetailPage`, `WorkspacePage` and `CaptureJourneySheetPage` through `MimicUITestCase`
/// instead of declaring a second set of queries for the same panel.
///
/// Three rules from `mimic-ui-tests` shape almost every query below, and each one has already cost
/// this suite time:
///
/// - **The drawer's header carries `ds.panelheader.requestLog` over its leaves**, so its clear
///   button, method menu, filter field and All / Unmatched / Errors segments are matched by label or
///   by identifier, whichever survives. `RequestLogDrawerPage.clearButton` queries
///   `clearRequestLogButton`, which the header may stamp over, so this file matches its label.
/// - **The table header is a plain `HStack`, so its `drawer.columnHeader.<field>` identifiers
///   survive** — Time, Method, Path, Status and Scenario sort; Duration and Size do not. Each carries
///   the sort direction in its `accessibilityValue`, which is what ``sortState(of:)`` reads.
/// - **A log row is one element**: `RequestLogTableRow` composes with
///   `.accessibilityElement(children: .ignore)`, so a row's method, path, endpoint, scenario, status
///   and time exist only inside its spoken label. Every assertion about a cell is therefore an
///   assertion about the row's label.
///
/// Traffic is always real: the server is started through the toolbar and the requests go over
/// `localhost`, so what the panels show is what the engine actually recorded.
final class RequestLogUITests: MimicUITestCase {

    // MARK: - Element helpers

    /// Any element carrying `identifier`, whatever AppKit realized it as.
    ///
    /// `.any` rather than a typed query throughout: a composed row arrives as a `Button`, a summary
    /// row as a `StaticText`, a status pill as either, and pinning the type is how a query silently
    /// stops matching after a styling change.
    @MainActor
    private func element(identifiedBy identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// For a control whose identifier has two possible spellings — a `DSMethodLabel` prefixes the
    /// name it is handed, so the request line's method is either `requestDetail.method` or
    /// `ds.method.requestDetail.method` depending on which modifier won.
    @MainActor
    private func element(identifiedByAnyOf identifiers: [String]) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", identifiers))
            .firstMatch
    }

    /// Every element whose identifier starts with `prefix`. `BEGINSWITH`, never `CONTAINS`: a
    /// `CONTAINS` predicate over `descendants(matching: .any)` is evaluated against every element in
    /// the window and times out inside XCUITest's own query evaluation, which is how
    /// `testArrowKeysMoveThroughTheRequestLog` first failed.
    @MainActor
    private func elements(identifierPrefix prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    /// Label and value as one string.
    ///
    /// Which of the two a `StaticText` carries its text in depends on how SwiftUI realized it — a
    /// `DSEmptyState`'s heading arrives as the value, a `DSStatusLabel`'s code as the label — and the
    /// sort headers deliberately put their state in the value while keeping a fixed label. Reading
    /// both is the only form that survives all three.
    @MainActor
    private func text(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "\(element.label)|\(value)"
    }

    /// Everything an element **and everything inside it** says.
    ///
    /// A control that is one view in the source is not always one element in the tree: a wrapper can
    /// take the identifier while the words stay on the `Text` beneath it, and then the handle a test
    /// holds reads as empty while the string it is asserting on is one level down. Reading the
    /// subtree is what makes an assertion about what a control says independent of how SwiftUI split
    /// it up.
    @MainActor
    private func speech(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        var parts = [text(of: element)]
        let inner = element.descendants(matching: .any)
        for index in 0..<inner.count {
            parts.append(text(of: inner.element(boundBy: index)))
        }
        return parts.joined(separator: " ")
    }

    /// Polls until `condition` holds, spaced by the accessibility queries the condition itself
    /// performs. Never `sleep()` — see rule 9 of the UI Definition of Done.
    @MainActor
    @discardableResult
    private func poll(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.windows.firstMatch.exists
        }
        return condition()
    }

    /// The first of `candidates` that exists, polled **together** rather than waited out in turn.
    @MainActor
    private func firstExisting(_ candidates: [XCUIElement], timeout: TimeInterval = 5) -> XCUIElement? {
        guard UITestApp.waitForAny(candidates, timeout: timeout) else { return nil }
        return candidates.first { $0.exists }
    }

    // MARK: - Drawer chrome

    /// The trash button in the drawer's header, by its label ("Clear request log") so the query
    /// survives the header's identifier being stamped over its leaves.
    @MainActor
    private var clearLogButton: XCUIElement { app.buttons["Clear request log"].firstMatch }

    /// Everything in the drawer's header, as one string, for a failure message. Guarded on
    /// `firstMatch.exists` because `count` on an empty query raises rather than answering zero.
    @MainActor
    private func spokenHeaderControls() -> String {
        let query = app.descendants(matching: .any).matching(identifier: "ds.panelheader.requestLog")
        guard query.firstMatch.exists else { return "<nothing carries ds.panelheader.requestLog>" }
        return (0..<query.count)
            .map { "[\(text(of: query.element(boundBy: $0)))]" }
            .joined(separator: " ")
    }

    /// The method filter: a menu at the leading edge of the filter field, labelled "Filter by
    /// method". Matched on the label fragment across the element types a `Menu` can realize as.
    @MainActor
    private var methodFilterControl: XCUIElement {
        let byIdentifier = app.menuButtons["drawer.methodFilter"].firstMatch
        if byIdentifier.exists { return byIdentifier }
        let carriesTheLabel = NSPredicate(format: "label CONTAINS %@", "Filter by method")
        let byMenuButton = app.menuButtons.matching(carriesTheLabel).firstMatch
        if byMenuButton.exists { return byMenuButton }
        let byPopUp = app.popUpButtons.matching(carriesTheLabel).firstMatch
        if byPopUp.exists { return byPopUp }
        let byButton = app.buttons.matching(carriesTheLabel).firstMatch
        if byButton.exists { return byButton }
        return app.descendants(matching: .any).matching(carriesTheLabel).firstMatch
    }

    /// The inspector's header, which is how the inspector's presence is witnessed.
    @MainActor
    private var inspectorHeader: XCUIElement { InspectorPage(app: app).header }

    /// Gives the drawer's header the width its controls need before one of them is clicked, by
    /// hiding the inspector (⌥⌘I). A control laid out past the hosting view's edge answers queries
    /// but cannot be clicked. Idempotent: it never opens the inspector.
    @MainActor
    private func widenCentrePaneByHidingTheInspector() {
        guard inspectorHeader.exists else { return }
        app.typeKey("i", modifierFlags: [.command, .option])
        _ = inspectorHeader.waitForNonExistence(timeout: 5)
    }

    /// The text filter, by identifier or by its label ("Filter request log"), polled together.
    @MainActor
    private func filterField() throws -> XCUIElement {
        let byIdentifier = app.descendants(matching: .textField)
            .matching(identifier: "drawer.filterField").firstMatch
        let byLabel = app.textFields["Filter request log"].firstMatch
        return try XCTUnwrap(
            firstExisting([byIdentifier, byLabel]),
            "The drawer should offer a filter field once the log has entries"
        )
    }

    /// The All / Unmatched / Errors segments. Each segment is a button carrying `.isSelected` when
    /// chosen; its label is the title, then ", N" when there is something to count.
    @MainActor
    private func scopeSegment(identifier: String, title: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                identifier, title, "\(title), "
            )
        ).firstMatch
    }

    @MainActor
    private var unmatchedSegment: XCUIElement {
        scopeSegment(identifier: "drawer.unmatchedFilter", title: "Unmatched")
    }

    @MainActor
    private var allSegment: XCUIElement {
        scopeSegment(identifier: "drawer.scope.all", title: "All")
    }

    @MainActor
    private var errorsSegment: XCUIElement {
        scopeSegment(identifier: "drawer.errorsFilter", title: "Errors")
    }

    /// The drawer header's "N requests" count, by its text and one of the identifiers a flattened
    /// leaf may carry.
    @MainActor
    private func headerCount(_ count: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "(value == %@ OR label == %@)"
                    + " AND (identifier == %@ OR identifier == %@ OR identifier == %@)",
                count, count,
                "ds.panelheader.requestLog", "ds.panelheader.subtitle.requestLog", ""
            )
        ).firstMatch
    }

    // MARK: - Rows

    /// How many rows the log is showing, counted **without resolving any of them**.
    ///
    /// This is the whole fix for `testFilteringTheRequestLogByTextAndMethod`, which did not fail an
    /// assertion at all — it died inside `RequestLogDrawerPage.distinctRows(limit:)` with "Failed to
    /// get matching snapshot: No matches found for … requestLog-". That helper takes the query's
    /// `count` from one snapshot and then reads `identifier` off each match, which is a second query;
    /// every filter in this test rebuilds the table, so the second query can find nothing where the
    /// first found rows, and a vanished element is a hard error rather than a smaller number. The
    /// wait loops below poll continuously, so they sat directly in that window.
    ///
    /// `count` never resolves an element, so a rebuild between two polls is just a different number.
    /// One element per row is safe to rely on: `RequestLogTableRow` composes with
    /// `.accessibilityElement(children: .ignore)` before it sets `requestLog-<uuid>`, so the row's six
    /// cells exist only inside its spoken label. The context-menu items are `requestLog.` with a dot
    /// and are not matched by this prefix.
    @MainActor
    private func visibleRowCount() -> Int {
        elements(identifierPrefix: "requestLog-").count
    }

    /// The rows themselves, for the assertions that need to read a label rather than count.
    ///
    /// Only ever called once a wait on ``visibleRowCount()`` has settled, and each row is checked for
    /// existence before it is read, so this resolves a stable table rather than one mid-rebuild.
    @MainActor
    private func visibleRows(limit: Int) -> [XCUIElement] {
        let query = elements(identifierPrefix: "requestLog-")
        var rows: [XCUIElement] = []
        var seen: Set<String> = []
        for index in 0..<query.count {
            let row = query.element(boundBy: index)
            guard row.exists, seen.insert(row.identifier).inserted else { continue }
            rows.append(row)
            if rows.count == limit { break }
        }
        return rows
    }

    /// Waits for `count` requests to have reached the log.
    ///
    /// The local counterpart of `RequestLogDrawerPage.waitForRowCount(_:timeout:)`, which resolves
    /// every row on every poll for the reason above.
    @MainActor
    @discardableResult
    private func waitForRowsToArrive(_ count: Int, timeout: TimeInterval = 15) -> Bool {
        poll(timeout: timeout) { self.visibleRowCount() >= count }
    }

    /// One logged row, re-addressed by identifier so it stays the same row across a re-sort.
    @MainActor
    private func logRow(_ identifier: String) -> XCUIElement {
        element(identifiedBy: identifier)
    }

    /// The identifier of the row whose spoken label names `path`.
    ///
    /// A test cannot know a log entry's UUID — the server mints it — and the row's cells do not exist
    /// as elements, so the composed label is the only way to tell two rows apart. The scan runs over
    /// the handful of rows the page object already resolved rather than as a `CONTAINS` predicate over
    /// the whole window.
    @MainActor
    private func rowIdentifier(forPath path: String, limit: Int = 8) -> String? {
        visibleRows(limit: limit).first { $0.label.contains(path) }?.identifier
    }

    @MainActor
    private func rowLabel(forPath path: String, limit: Int = 8) -> String {
        visibleRows(limit: limit).first { $0.label.contains(path) }?.label ?? ""
    }

    /// Waits for the log to be showing exactly `count` rows — the observable half of every filter
    /// assertion in this file.
    @MainActor
    @discardableResult
    private func waitForVisibleRowCount(_ count: Int, timeout: TimeInterval = 8) -> Bool {
        poll(timeout: timeout) { self.visibleRowCount() == count }
    }

    @MainActor
    private func firstRowLabel() -> String {
        visibleRows(limit: 1).first?.label ?? ""
    }

    // MARK: - Sorting

    @MainActor
    private func columnHeader(_ field: String) -> XCUIElement {
        element(identifiedBy: "drawer.columnHeader.\(field)")
    }

    /// What a column header announces: `"sorted ascending"`, `"sorted descending"`, or nothing at all
    /// when it is not the sorted column. It rides in the value so the label can stay the fixed string
    /// "Sort by status" whichever way the chevron points.
    @MainActor
    private func sortState(of field: String) -> String {
        text(of: columnHeader(field))
    }

    @MainActor
    @discardableResult
    private func waitForSortState(_ field: String, _ state: String, timeout: TimeInterval = 5) -> Bool {
        poll(timeout: timeout) { self.sortState(of: field).contains(state) }
    }

    /// Clicks a column header and waits for it to report the direction the click should have produced.
    @MainActor
    private func sort(by field: String, expecting state: String) {
        let header = columnHeader(field)
        XCTAssertTrue(header.waitForExistence(timeout: 5), "The \(field) column header should be addressable")
        header.click()
        XCTAssertTrue(
            waitForSortState(field, state),
            "Clicking the \(field) column should leave it \(state) — it reported \(sortState(of: field))"
        )
    }

    // MARK: - Shared arrangement

    /// Opens a project on `port` and starts the server, so the log has somewhere to come from.
    @MainActor
    private func startServer(projectNamed name: String, port: Int) {
        createProjectViaUI(name: name, port: port)
        workspace.fillWindow()
        workspace.toggleServer()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "The server should report its base URL once running"
        )
    }

    @MainActor
    func testPassedThroughInspectorSavesTextAndRefusesBinary() async throws {
        let ready = expectation(description: "Synthetic backend ready")
        let fixture = try PassthroughUIBackend(port: 62131) { ready.fulfill() }
        defer { fixture.stop() }
        await fulfillment(of: [ready], timeout: 5)
        launchApp()
        createProjectViaUI(name: "Real backend capture", port: 62130)
        workspace.fillWindow()
        let settings = BackendSettingsPage(app: app)
        XCTAssertTrue(settings.open.waitForExistence(timeout: 5))
        settings.open.click()
        XCTAssertTrue(settings.primaryName.waitForExistence(timeout: 5))
        settings.replace(settings.primaryName, with: "Catalog")
        settings.primaryEnabled.click()
        settings.replace(settings.primaryUpstream, with: "http://127.0.0.1:62131")
        settings.apply.click()
        XCTAssertTrue(settings.apply.waitForNonExistence(timeout: 5))
        workspace.toggleServer()
        XCTAssertTrue(workspace.waitForServerURL(port: 62130))
        await sendRequest(port: 62130, path: "/profile")
        await sendRequest(port: 62130, path: "/binary")
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15))
        XCTAssertTrue(rowLabel(forPath: "/binary").contains("passed through"), rowLabel(forPath: "/binary"))
        logRow(try XCTUnwrap(rowIdentifier(forPath: "/binary"))).click()
        XCTAssertTrue(requestDetail.waitForDetail(), app.debugDescription)
        let save = app.buttons["requestDetail.saveMock"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(save.isEnabled)
        // Why it cannot be saved sits beside what answered, on the Response tab.
        requestDetail.tab("Response").click()
        XCTAssertTrue(element(identifiedBy: "requestDetail.captureIssue").waitForExistence(timeout: 5))
        let binaryBodyNote = element(identifiedBy: "requestDetail.body.response.empty")
        XCTAssertTrue(binaryBodyNote.waitForExistence(timeout: 5))
        XCTAssertTrue([binaryBodyNote.label, binaryBodyNote.value as? String ?? ""].contains(
            "Binary or non-UTF-8 response body is not previewed"
        ), "The full explanation must be accessible, got \(text(of: binaryBodyNote))")
        logRow(try XCTUnwrap(rowIdentifier(forPath: "/profile"))).click()
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(poll { save.isEnabled }, app.debugDescription)
        XCTAssertTrue(speech(of: element(identifiedBy: "requestDetail.summary.backend")).contains("Catalog"), app.debugDescription)
        let drawer = element(identifiedBy: "drawer")
        let methodHeader = element(identifiedBy: "drawer.columnHeader.method")
        XCTAssertGreaterThanOrEqual(methodHeader.frame.minX, drawer.frame.minX,
                                    "Narrow traffic tables must keep their leading column visible")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Passed-through request — backend and capture action"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        settings.open.click()
        XCTAssertTrue(settings.primaryEnabled.waitForExistence(timeout: 5))
        settings.primaryEnabled.click()
        settings.apply.click()
        XCTAssertTrue(settings.apply.waitForNonExistence(timeout: 5))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:62130/profile")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"account":"Ada"}"#)
    }

    // MARK: - LOGSORT

    /// Every column header sorts, and clicking the sorted one reverses it.
    ///
    /// The direction is asserted from `accessibilityValue` — the only place it is stated, since the
    /// chevron is an unlabelled `Image` inside the button and deliberately carries no identifier of
    /// its own. The row order is asserted alongside it, so a header that announces "sorted ascending"
    /// while the table stays put still fails.
    @MainActor
    func testSortingTheRequestLogByEachColumnHeader() async throws {
        let port = 62101

        launchApp()
        startServer(projectNamed: "Sort Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/zeta", method: "POST", body: nil)
        await sendRequest(port: port, path: "/api/alpha", method: "GET", body: nil)

        XCTAssertTrue(
            waitForRowsToArrive(3, timeout: 15),
            "All three requests should reach the log"
        )
        // Scenario, Duration and Size are hidden in the compact table, which the log uses below
        // `LogColumns.minimumTableWidth` (766pt). Give the table the wide centre pane before
        // exercising all five sortable columns: hide the inspector, and on a display as narrow as
        // CI's 1024pt the navigator too. The headers only render once traffic arrives, so this must
        // follow the row-count wait.
        if !columnHeader("scenario").exists {
            widenCentrePaneByHidingTheInspector()
        }
        if !columnHeader("scenario").waitForExistence(timeout: 2) {
            workspace.hideSidebarIfShown()
        }
        XCTAssertTrue(columnHeader("scenario").waitForExistence(timeout: 5),
                      "The wide request log should expose the Scenario column")
        XCTAssertFalse(columnHeader("endpoint").exists,
                       "What answered shares the Scenario column; there is no Endpoint column any more")

        // The log opens on Time, newest first — the one column that starts active, and the one case
        // `nextSortState` treats specially.
        XCTAssertTrue(
            waitForSortState("timestamp", "sorted descending"),
            "The log should open sorted by time, newest first"
        )
        XCTAssertFalse(
            sortState(of: "path").contains("sorted"),
            "Only the sorted column should announce a direction"
        )

        // Path: a fresh column starts ascending, so the alphabetically first path leads.
        sort(by: "path", expecting: "sorted ascending")
        XCTAssertTrue(
            poll { self.firstRowLabel().hasPrefix("GET /api/alpha") },
            "Sorting by path ascending should put /api/alpha first — first row was \(firstRowLabel())"
        )
        XCTAssertFalse(
            sortState(of: "timestamp").contains("sorted"),
            "Time should stop announcing a direction once Path is the sorted column"
        )

        // The same column again reverses rather than re-sorting.
        sort(by: "path", expecting: "sorted descending")
        XCTAssertTrue(
            poll { self.firstRowLabel().hasPrefix("POST /api/zeta") },
            "Reversing the path sort should put /api/zeta first — first row was \(firstRowLabel())"
        )

        sort(by: "method", expecting: "sorted ascending")
        XCTAssertTrue(
            poll { self.firstRowLabel().hasPrefix("GET ") },
            "Sorting by method ascending should put a GET first — first row was \(firstRowLabel())"
        )

        // Scenario has no order worth asserting on three rows — two of them are unmatched and share
        // an empty key — so this asserts the state the header reports, which is what a reader gets.
        sort(by: "scenario", expecting: "sorted ascending")

        sort(by: "status", expecting: "sorted ascending")
        XCTAssertTrue(
            poll { self.firstRowLabel().contains("status 200") },
            "Sorting by status ascending should put the 200 above the 404s — first row was \(firstRowLabel())"
        )

        // Time is the exception: `nextSortState` gives a newly requested column ascending order
        // unless it is the timestamp, which starts newest-first because that is what a log is read as.
        sort(by: "timestamp", expecting: "sorted descending")
        XCTAssertTrue(
            poll { self.firstRowLabel().contains("/api/alpha") },
            "Sorting by time should put the newest request first — first row was \(firstRowLabel())"
        )
    }

    // MARK: - LOGFILT (text and method)

    /// The filter field's three predicates — path, status code, outcome word — the method menu, and
    /// the empty state a filter that matches nothing falls back to.
    @MainActor
    func testFilteringTheRequestLogByTextAndMethod() async throws {
        let port = 62102

        launchApp()
        startServer(projectNamed: "Filter Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "POST", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)

        XCTAssertTrue(
            waitForRowsToArrive(3, timeout: 15),
            "All three requests should reach the log"
        )
        XCTAssertTrue(
            headerCount("3 requests").waitForExistence(timeout: 5),
            "The header should count what the log is showing"
        )

        let field = try filterField()

        // Path fragment.
        field.click()
        field.typeText("orders")
        XCTAssertTrue(waitForVisibleRowCount(2), "Filtering on a path fragment should leave the two /api/orders calls")
        XCTAssertTrue(
            headerCount("2 requests").waitForExistence(timeout: 5),
            "The header count should fall to what the filter left"
        )

        // Status code — the second arm of the predicate.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("404")
        XCTAssertTrue(waitForVisibleRowCount(2), "Filtering on 404 should leave the two unmatched calls")

        // Outcome word — the third arm.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("unmatched")
        XCTAssertTrue(waitForVisibleRowCount(2), "Filtering on an outcome word should leave the two unmatched calls")

        // Nothing matches: the panel explains itself rather than showing a blank table.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("zzzznothing")
        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    requestLogDrawer.noMatchesHeading,
                    element(identifiedBy: "ds.empty.drawer.noMatches.heading"),
                    element(identifiedBy: "ds.empty.drawer.noMatches"),
                ],
                timeout: 5
            ),
            "A filter that matches nothing should show the 'No matching requests' state"
        )
        XCTAssertFalse(
            requestLogDrawer.emptyHeading.exists,
            "The idle empty state is a different state — the log still holds three entries"
        )

        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitForVisibleRowCount(3), "Clearing the filter should bring every row back")

        // The method menu at the filter field's leading edge, reached by identifier or label; see
        // ``methodFilterControl``. Its items are ordinary menu elements once it is open.
        XCTAssertTrue(
            methodFilterControl.waitForExistence(timeout: 5),
            "The method filter should be addressable — the drawer header is saying "
                + spokenHeaderControls()
        )
        methodFilterControl.click()
        let postItem = app.menuItems["POST"]
        XCTAssertTrue(postItem.waitForExistence(timeout: 5), "The method menu should offer POST")
        postItem.click()

        XCTAssertTrue(waitForVisibleRowCount(1), "Filtering by POST should leave the one POST")
        XCTAssertTrue(
            poll { self.firstRowLabel().hasPrefix("POST ") },
            "The surviving row should be the POST — it was \(firstRowLabel())"
        )

        methodFilterControl.click()
        let allItem = app.menuItems["All"]
        XCTAssertTrue(allItem.waitForExistence(timeout: 5), "The method menu should offer All")
        allItem.click()
        XCTAssertTrue(waitForVisibleRowCount(3), "Choosing All should clear the method filter")

        await sendRequest(port: port, path: "/api/probe", method: "HEAD", body: nil)
        await sendRequest(port: port, path: "/api/probe", method: "OPTIONS", body: nil)
        XCTAssertTrue(waitForRowsToArrive(5, timeout: 15))
        for method in ["HEAD", "OPTIONS"] {
            methodFilterControl.click()
            let item = app.menuItems[method]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "The method filter should offer \(method)")
            item.click()
            XCTAssertTrue(waitForVisibleRowCount(1), "Filtering by \(method) should leave its one request")
            XCTAssertTrue(poll { self.firstRowLabel().hasPrefix("\(method) ") }, firstRowLabel())
        }
    }

    // MARK: - LOGFILT (unmatched) and clearing the log

    /// The All / Unmatched / Errors segments — counted once there is something to count — the
    /// toolbar badge that selects Unmatched from outside the panel, and the trash button that empties
    /// the log.
    @MainActor
    func testUnmatchedOnlyFilterAndClearingTheLog() async throws {
        let port = 62103

        launchApp()
        startServer(projectNamed: "Unmatched Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(1, timeout: 15), "The matched request should reach the log")

        // Nothing unmatched and nothing failed: the segments carry no counts, and All is chosen.
        XCTAssertTrue(unmatchedSegment.waitForExistence(timeout: 5),
                      "The Unmatched segment should be in the header — it is saying " + spokenHeaderControls())
        XCTAssertEqual(unmatchedSegment.label, "Unmatched", "With nothing unmatched the segment should carry no count")
        XCTAssertEqual(errorsSegment.label, "Errors", "With nothing failed the Errors segment should carry no count")
        XCTAssertTrue(allSegment.isSelected, "The log should open on All")

        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "The unmatched request should reach the log")

        XCTAssertTrue(
            poll { self.unmatchedSegment.label == "Unmatched, 1" },
            "The Unmatched segment should carry the count — it read \(unmatchedSegment.label)"
        )
        // The unmatched call is answered with a 404, so it is also the one error.
        XCTAssertTrue(
            poll { self.errorsSegment.label == "Errors, 1" },
            "The Errors segment should count the 404 — it read \(errorsSegment.label)"
        )

        // The toolbar's badge is the other way in: it opens the drawer already filtered, the way
        // Xcode's warning count jumps you to the issue navigator.
        ServerStatusWellPage(app: app).revealTrafficControlsIfCompact()
        let toolbarBadge = app.buttons["1 unmatched request, show it"].firstMatch
        if toolbarBadge.waitForExistence(timeout: 2) {
            toolbarBadge.click()
        } else {
            // On a compact display the well intentionally hides traffic counts. The center
            // toolbar's overflow menu keeps the same unmatched-request action reachable.
            let overflow = WorkspacePage(app: app).overflowMenu
            XCTAssertTrue(overflow.waitForExistence(timeout: 5))
            XCTAssertEqual(overflow.value as? String, "1 unmatched request")
            overflow.click()
            let showUnmatched = app.menuItems["toolbar.showUnmatched"]
            XCTAssertTrue(showUnmatched.waitForExistence(timeout: 5))
            showUnmatched.click()
        }
        XCTAssertTrue(waitForVisibleRowCount(1), "The badge should filter the log down to the unmatched call")
        XCTAssertTrue(
            poll { self.firstRowLabel().contains("unmatched") },
            "The surviving row should be the unmatched one — it was \(firstRowLabel())"
        )
        XCTAssertTrue(poll { self.unmatchedSegment.isSelected }, "The badge should select the Unmatched segment")

        // All brings the full log back; Errors narrows to the failed call; Unmatched again from the
        // panel's own control.
        allSegment.click()
        XCTAssertTrue(waitForVisibleRowCount(2), "All should bring the full log back")
        XCTAssertTrue(poll { self.allSegment.isSelected && !self.unmatchedSegment.isSelected })

        errorsSegment.click()
        XCTAssertTrue(waitForVisibleRowCount(1), "Errors should leave only the 404")
        XCTAssertTrue(
            poll { self.firstRowLabel().contains("status 404") },
            "The surviving row should be the 404 — it was \(firstRowLabel())"
        )

        unmatchedSegment.click()
        XCTAssertTrue(waitForVisibleRowCount(1), "Unmatched should narrow to the unmatched call again")
        XCTAssertTrue(poll { self.unmatchedSegment.isSelected })

        // Clearing empties the log outright, and the panel falls back to its idle state — not to the
        // "No matching requests" one, which would be a filter still claiming to be filtering.
        XCTAssertTrue(clearLogButton.waitForExistence(timeout: 5), "The header should offer a clear button")

        // Keep the inspector open. The filter moves to a second pinned row when the centre pane
        // narrows, so the clear action must remain reachable without changing the user's layout.
        // Existence alone would miss a button drawn outside the pane's bounds.
        XCTAssertTrue(
            poll { self.clearLogButton.isHittable },
            "The clear button should be somewhere the pointer can reach it — it is at "
                + "\(clearLogButton.frame) inside a window of \(app.windows.firstMatch.frame). A "
                + "button that exists, carries the right label and is not hittable is the drawer's "
                + "header overflowing its pane, not a query that resolved the wrong element."
        )
        clearLogButton.click()

        // Two assertions, in this order, because they fail for different reasons: the rows going is
        // the clear having happened at all, and the empty state is what the panel does about it.
        XCTAssertTrue(
            waitForVisibleRowCount(0),
            "The trash button should empty the log — the header still reads "
                + spokenHeaderControls()
        )

        // `RequestLogDrawerView` checks `requestLogs.isEmpty` before it checks the filter, so a
        // cleared log shows the idle empty state even with Unmatched still selected. The heading and
        // its container are polled together with the page object's text match.
        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    requestLogDrawer.emptyHeading,
                    element(identifiedBy: "ds.empty.drawer.requests.heading"),
                    element(identifiedBy: "ds.empty.drawer.requests"),
                ],
                timeout: 5
            ),
            "Clearing the log should restore the idle empty state"
        )

        // The negative is checked on the identifier prefix rather than on the heading's label: a
        // label query that cannot resolve the element would pass this assertion by not finding
        // something that is on screen.
        XCTAssertEqual(
            elements(identifierPrefix: "ds.empty.drawer.noMatches").count,
            0,
            "An empty log is not a filtered-out log"
        )
        XCTAssertEqual(visibleRowCount(), 0, "No rows should survive the clear")
    }

    // MARK: - LOGVIEW rows and REQDET summary/headers

    /// What a row says out loud, what the header counts, and all three tabs of the request detail:
    /// Request, Response and Timing.
    @MainActor
    func testRowLabelsAndRequestDetailSummaryAndHeaders() async throws {
        let port = 62104
        let payload = #"{"name":"Ada Lovelace","role":"engineer"}"#

        launchApp()
        startServer(projectNamed: "Detail Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users", method: "POST")

        await sendRequest(port: port, path: "/api/users", method: "POST", body: payload)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)

        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "Both requests should reach the log")
        XCTAssertTrue(
            headerCount("2 requests").waitForExistence(timeout: 5),
            "The drawer header should count the requests it is showing"
        )

        // The cells exist only inside the composed label, so this is the assertion that the method,
        // path, status and what answered are saying the right things.
        let matchedLabel = rowLabel(forPath: "/api/users")
        XCTAssertTrue(
            matchedLabel.contains("POST /api/users") && matchedLabel.contains("status 200"),
            "The matched row should announce its method, path and status — it read \(matchedLabel)"
        )
        XCTAssertTrue(
            matchedLabel.contains("endpoint Users") && matchedLabel.contains("scenario Default"),
            "The matched row should name what answered it — it read \(matchedLabel)"
        )

        let unmatchedLabel = rowLabel(forPath: "/api/orders")
        XCTAssertTrue(
            unmatchedLabel.contains("status 404") && unmatchedLabel.contains(", unmatched"),
            "An unmatched row should say so rather than leaving the scenario column silent — it read \(unmatchedLabel)"
        )

        let matchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/users"), "The matched row should be addressable")
        logRow(matchedID).click()
        XCTAssertTrue(
            requestDetail.waitForDetail(),
            "Clicking a row should open its detail beside the log"
        )
        XCTAssertTrue(
            requestDetail.goToEndpointButton.waitForExistence(timeout: 5),
            "A request an endpoint answered should offer to open that endpoint"
        )
        XCTAssertFalse(requestDetail.createEndpointButton.exists, "An answered request needs no new endpoint")

        // The identity block: method, status and time. `DSMethodLabel` prefixes the identifier it is
        // handed, so both spellings are matched.
        let methodBadge = element(identifiedByAnyOf: ["requestDetail.method", "ds.method.requestDetail.method"])
        XCTAssertTrue(methodBadge.waitForExistence(timeout: 5), "The identity line should show the method badge")
        XCTAssertTrue(
            text(of: methodBadge).contains("POST"),
            "The badge should name the method — it read \(text(of: methodBadge))"
        )
        XCTAssertTrue(requestDetail.status.waitForExistence(timeout: 5), "The identity line should show the status")
        XCTAssertTrue(
            text(of: requestDetail.status).contains("200"),
            "The status pill should carry the code — it read \(text(of: requestDetail.status))"
        )
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.timestamp").waitForExistence(timeout: 5),
            "The identity line should show when the request arrived"
        )
        let outcomeSentence = element(identifiedBy: "requestDetail.outcome")
        XCTAssertTrue(outcomeSentence.waitForExistence(timeout: 5), "The identity block should say what answered")
        XCTAssertTrue(
            text(of: outcomeSentence).contains("Answered by Users"),
            "The outcome sentence should name the endpoint — it read \(text(of: outcomeSentence))"
        )

        // Request is the tab a selection opens on: where the call arrived, then its headers.
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.request.summary").waitForExistence(timeout: 5),
            "The Request tab should head its first section 'Summary'"
        )
        let urlRow = element(identifiedBy: "requestDetail.summary.url")
        XCTAssertTrue(urlRow.waitForExistence(timeout: 5), "The Request tab should show the URL the client called")
        XCTAssertTrue(text(of: urlRow).contains("/api/users"), "The URL should carry the path — it read \(text(of: urlRow))")
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.headers.request").waitForExistence(timeout: 5),
            "The Request tab should list the request headers"
        )
        // Assert on the rows rather than only on the section title — and pair the count with the
        // absence of the empty note, because "no headers" renders under the same prefix.
        XCTAssertFalse(
            element(identifiedBy: "requestDetail.headers.request.empty").exists,
            "A request carrying headers should not show the empty note"
        )
        XCTAssertTrue(
            poll { self.elements(identifierPrefix: "requestDetail.headers.request.").count > 0 },
            "The request headers the client actually sent should be listed"
        )

        // Response: what answered, then the response's own headers.
        requestDetail.tab("Response").click()
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.answeredBy").waitForExistence(timeout: 5),
            "The Response tab should head its first section 'Answered by'"
        )
        let outcomeRow = element(identifiedBy: "requestDetail.summary.outcome")
        XCTAssertTrue(outcomeRow.waitForExistence(timeout: 5), "Response should state the outcome")
        XCTAssertTrue(
            text(of: outcomeRow).localizedCaseInsensitiveContains("endpoint"),
            "An endpoint answered this call — the row read \(text(of: outcomeRow))"
        )
        XCTAssertTrue(
            text(of: element(identifiedBy: "requestDetail.summary.endpoint")).contains("Users"),
            "Response should name the endpoint that answered"
        )
        XCTAssertTrue(
            text(of: element(identifiedBy: "requestDetail.summary.scenario")).contains("Default"),
            "Response should name the scenario that answered"
        )
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.headers.response").exists,
            "The Response tab should head the response headers, naming what answered"
        )
        XCTAssertFalse(
            element(identifiedBy: "requestDetail.headers.response.empty").exists,
            "An answered request should not show the no-response note"
        )
        XCTAssertTrue(
            elements(identifierPrefix: "requestDetail.headers.response.").count > 0,
            "The response headers the client received should be listed"
        )

        // Timing: when it arrived, how long it took, and what each half carried.
        requestDetail.tab("Timing").click()
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.timing").waitForExistence(timeout: 5),
            "The Timing tab should head its first section 'Timing'"
        )
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.summary.received").exists,
            "Timing should say when the request arrived"
        )
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.sizes").exists,
            "The Timing tab should head its second section 'Sizes'"
        )
        for row in ["request body", "response body", "request headers", "response headers"] {
            XCTAssertTrue(
                element(identifiedBy: "requestDetail.summary.\(row)").exists,
                "Timing should report the \(row)"
            )
        }

        // And back — the tab is a segmented picker, so this is a different control from the close
        // button that leaves request detail altogether.
        requestDetail.tab("Response").click()
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.summary.outcome").waitForExistence(timeout: 5),
            "Switching back to Response should show the answered-by rows again"
        )
    }

    // MARK: - REQDET bodies, the unmatched header and copy actions

    /// The request and response bodies across the two shapes a logged exchange actually takes — a
    /// matched call whose default scenario returns nothing, and an unmatched one whose body is
    /// Mimic's own fallback — plus the unmatched header's explanation and Create endpoint, and the
    /// row menu's Copy response body.
    @MainActor
    func testRequestDetailBodiesAndUnmatchedHeader() async throws {
        let port = 62105
        let payload = #"{"name":"Ada Lovelace","role":"engineer"}"#

        launchApp()
        startServer(projectNamed: "Body Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users", method: "POST")

        await sendRequest(port: port, path: "/api/users", method: "POST", body: payload)
        await sendRequest(port: port, path: "/api/orders?limit=4", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "Both requests should reach the log")

        let matchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/users"), "The matched row should be addressable")
        let unmatchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/orders"), "The unmatched row should be addressable")

        logRow(matchedID).click()
        XCTAssertTrue(requestDetail.waitForDetail(), "The clicked request should open beside the log")
        requestDetail.tab("Response").click()

        // A new endpoint's default scenario has no body, so this is the empty arm — the one a reader
        // meets most often.
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.body.response.empty").waitForExistence(timeout: 5),
            "A scenario with no body should say so rather than rendering nothing"
        )
        // The faint Response / All copy pair is gone; copying a body lives in the row's menu.
        XCTAssertFalse(element(identifiedBy: "requestDetail.copy.responseBody").exists)
        XCTAssertFalse(element(identifiedBy: "requestDetail.copy.all").exists)

        // The payload is on the Request tab, and there is no find field over it.
        requestDetail.tab("Request").click()
        XCTAssertTrue(
            element(identifiedBy: "requestLog.body.request").waitForExistence(timeout: 5),
            "The POST payload should be rendered on the Request tab"
        )
        XCTAssertFalse(element(identifiedBy: "requestDetail.bodySearchField").exists, "The detail has no find field")

        // The unmatched call is the mirror image: a query, no request body, and a header that says
        // what Mimic did and offers the fix.
        logRow(unmatchedID).click()
        XCTAssertTrue(
            poll { self.requestDetail.shownPath().contains("/api/orders") },
            "Selecting another row should show it — the detail read \(requestDetail.shownPath())"
        )
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.query").waitForExistence(timeout: 5),
            "A request with a query string should list its items"
        )
        XCTAssertTrue(
            speech(of: element(identifiedBy: "requestDetail.query.0")).contains("limit"),
            "The query row should name the item"
        )
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.body.request.empty").waitForExistence(timeout: 5),
            "A GET with no payload should say it has no body"
        )
        let outcomeSentence = element(identifiedBy: "requestDetail.outcome")
        XCTAssertTrue(
            poll { self.text(of: outcomeSentence).contains("No endpoint matched, so Mimic returned 404") },
            "The header should say what Mimic did — it read \(text(of: outcomeSentence))"
        )
        XCTAssertTrue(
            requestDetail.createEndpointButton.waitForExistence(timeout: 5),
            "An unmatched request should offer to create its endpoint"
        )
        XCTAssertFalse(requestDetail.goToEndpointButton.exists, "Nothing answered, so there is no endpoint to open")

        requestDetail.tab("Response").click()
        XCTAssertTrue(
            element(identifiedBy: "requestLog.body.response").waitForExistence(timeout: 5),
            "The fallback response body should be rendered"
        )
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.unmatchedHint").waitForExistence(timeout: 5),
            "An unmatched request should explain that Mimic answered with its fallback"
        )
        XCTAssertTrue(
            text(of: element(identifiedBy: "requestDetail.summary.outcome"))
                .localizedCaseInsensitiveContains("unmatched"),
            "Response should state the unmatched outcome"
        )

        // The row's menu copies the body the detail is showing.
        let clipboard = UITestClipboardSnapshot()
        defer { clipboard.restore() }
        NSPasteboard.general.clearContents()
        logRow(unmatchedID).rightClick()
        let copyBody = app.menuItems["Copy response body"]
        XCTAssertTrue(copyBody.waitForExistence(timeout: 5), "The row's context menu should offer Copy response body")
        copyBody.click()
        XCTAssertTrue(
            poll { NSPasteboard.general.string(forType: .string)?.isEmpty == false },
            "Copy response body should put the fallback body on the pasteboard"
        )

        // Create endpoint turns the call into a mock and gives the column back to the editor.
        requestDetail.createEndpointButton.click()
        XCTAssertTrue(
            poll { self.text(of: self.endpointEditor.pathLabel).contains("/api/orders") },
            "Creating an endpoint from the detail should open it in the editor — the editor showed "
                + text(of: endpointEditor.pathLabel)
        )
        XCTAssertTrue(requestDetail.path.waitForNonExistence(timeout: 5), "The detail should close")
    }

    @MainActor
    func testTruncatedRequestBodyIsDisclosedAndCannotBeCopiedAsCompleteCurl() async throws {
        let port = 62132
        let payload = String(repeating: "x", count: 65_537)

        launchApp()
        startServer(projectNamed: "Truncated request", port: port)
        await sendRequest(port: port, path: "/api/large", method: "POST", body: payload)
        XCTAssertTrue(waitForRowsToArrive(1, timeout: 15))
        logRow(try XCTUnwrap(rowIdentifier(forPath: "/api/large"))).click()
        XCTAssertTrue(requestDetail.waitForDetail())

        requestDetail.tab("Timing").click()
        let bodySummary = element(identifiedBy: "requestDetail.summary.request body")
        XCTAssertTrue(bodySummary.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: bodySummary).contains("64.0 KB (truncated)"), text(of: bodySummary))
        requestDetail.tab("Request").click()
        let truncation = element(identifiedBy: "requestDetail.body.request.truncated")
        XCTAssertTrue(truncation.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: truncation).contains("Truncated at 64 KB."), text(of: truncation))

        let curl = element(identifiedBy: "requestDetail.copy.curl")
        XCTAssertTrue(curl.waitForExistence(timeout: 5))
        XCTAssertFalse(curl.isEnabled, "A stored prefix cannot reproduce the original request")
        XCTAssertTrue(curl.label.contains("request body was truncated"), curl.label)

        // The row's menu refuses the same way.
        logRow(try XCTUnwrap(rowIdentifier(forPath: "/api/large"))).rightClick()
        let menuCurl = app.menuItems["Copy as cURL"]
        XCTAssertTrue(menuCurl.waitForExistence(timeout: 5), "The row's context menu should offer Copy as cURL")
        XCTAssertFalse(menuCurl.isEnabled, "The row's menu cannot copy a truncated request as cURL either")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(menuCurl.waitForNonExistence(timeout: 5))
        XCTAssertFalse(payload.isEmpty)
    }

    // MARK: - LOGCTX create endpoint

    /// Going from "this call is unmocked" to "it is mocked now" without retyping the method and path
    /// — and the other half of that rule: a row an endpoint already answered is not offered it.
    @MainActor
    func testCreatingAnEndpointFromAnUnmatchedLogRow() async throws {
        let port = 62106

        launchApp()
        startServer(projectNamed: "Create From Log", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "Both requests should reach the log")

        let matchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/users"), "The matched row should be addressable")
        let unmatchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/orders"), "The unmatched row should be addressable")

        // The negative case first, while nothing has been created. The journey item is the positive
        // anchor: it proves the menu is open, so the absent create item is evidence rather than a
        // menu that never appeared.
        logRow(matchedID).rightClick()
        let journeyItem = app.menuItems["Add to journey"]
        XCTAssertTrue(journeyItem.waitForExistence(timeout: 5), "The row's context menu should open")
        XCTAssertFalse(
            app.menuItems["Create endpoint for GET /api/users"].exists,
            "A row an endpoint already answered should not be offered a new endpoint"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(journeyItem.waitForNonExistence(timeout: 5), "Escape should dismiss the context menu")

        // Traffic remains available while editing journeys. Creating its missing mock must switch
        // the editor back to Endpoints rather than silently selecting an off-screen endpoint.
        let shell = WorkspaceShellPage(app: app)
        shell.journeysTab.click()
        // The journeys screen opens without the log, as designed; ⌥⌘L brings it back beside a journey.
        XCTAssertTrue(logRow(unmatchedID).waitForNonExistence(timeout: 5),
                      "The journeys screen should open without the request log")
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(logRow(unmatchedID).waitForExistence(timeout: 5),
                      "The request log toggle should show the log on the journeys screen")

        logRow(unmatchedID).rightClick()
        let createItem = app.menuItems["Create endpoint for GET /api/orders"]
        XCTAssertTrue(
            createItem.waitForExistence(timeout: 5),
            "An unmatched row should offer to create the endpoint it is missing"
        )
        createItem.click()

        // Creating it also selects it, so the editor is the observable half: the centre pane has to
        // stop showing /api/users.
        XCTAssertTrue(
            poll { self.text(of: self.endpointEditor.pathLabel).contains("/api/orders") },
            "Creating an endpoint from the log should open it in the editor — the editor showed "
                + text(of: endpointEditor.pathLabel)
        )
    }

    // MARK: - LOGCTX journeys

    /// The single-request half of the capture menu: the singular wording, a right-click outside the
    /// selection acting on the clicked row alone, a new journey from one request, and appending a
    /// later request to that journey by name.
    @MainActor
    func testAddingRequestsToAnExistingJourneyFromTheLog() async throws {
        let port = 62107

        launchApp()
        startServer(projectNamed: "Capture To Journey", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "Both requests should reach the log")

        let rows = visibleRows(limit: 2)
        XCTAssertEqual(rows.count, 2, "Both requests should be listed as separate rows")
        let identifiers = rows.map(\.identifier)

        // One row selected, then a right-click on the other — which is *outside* the selection, so
        // the menu must act on the clicked row alone rather than on rows the pointer is nowhere near.
        XCTAssertTrue(requestLogDrawer.reveal(logRow(identifiers[0])), "The first request must be visible")
        logRow(identifiers[0]).click()
        // Selecting a row moves the log into the centre column beside the request's detail, so every
        // row moves. Wait for the unselected row's frame to settle before clicking.
        UITestApp.waitForStableFrame(logRow(identifiers[1]))
        XCTAssertTrue(requestLogDrawer.reveal(logRow(identifiers[1])), "The second request must be visible")
        logRow(identifiers[1]).rightClick()

        let singularMenu = app.menuItems["Add to journey"]
        XCTAssertTrue(
            singularMenu.waitForExistence(timeout: 5),
            "A right-click outside the selection should offer to capture that one row; "
                + "menu items \(app.menuItems.allElementsBoundByIndex.map(\.title)), "
                + "rows \(identifiers.map { logRow($0).label })"
        )
        XCTAssertFalse(
            app.menuItems["Add 2 requests to journey"].exists,
            "The menu must not act on a selection the clicked row is not part of"
        )

        // The nested menu is driven through the shared helper rather than clicked here, and the
        // history is why. This line failed on run #91 waiting five seconds for the sheet; the reading
        // then was "the machine was busy and the clock was short", and the wait was widened to
        // fifteen. **Run #98 failed here twice in the same run, at fifteen.** A sheet that is merely
        // slow arrives inside fifteen seconds. One that never arrives is a different failure, and the
        // clock was never the thing to change — `UITestApp.chooseFromSubmenu` carries the account.
        //
        // Not a weakened assertion, and this matters more than it did before: every attempt the
        // helper makes ends waiting for this same field, so a capture that does not present still
        // fails here. What the helper removes is the *click* being lost, not the sheet being absent.
        let sheetAppeared = UITestApp.chooseFromSubmenu(
            in: app,
            parent: singularMenu,
            item: app.menuItems["New journey from this request\u{2026}"],
            thenAwait: captureSheet.nameField,
            reopenMenu: { self.logRow(identifiers[1]).rightClick() },
            menuIsAlreadyOpen: true
        )
        if !sheetAppeared {
            // Named rather than asserted, in the style this suite already uses for the capture menu:
            // the three states below are three different bugs and the message has to say which.
            // `journeyEditorOpen` is the discriminator worth having — a journey that exists without
            // the sheet ever appearing means the menu item's action *ran* and the presentation was
            // dropped, which is the app's fault and not the click's.
            let visible = app.menuItems.allElementsBoundByIndex.prefix(8).map(\.title)
            XCTFail(
                "Capturing into a new journey should ask for a name first. "
                    + "openMenus=\(app.menus.count) visibleMenuItems=\(visible) "
                    + "journeyEditorOpen=\(app.staticTexts["journeyEditor.name"].exists)"
            )
        }
        captureSheet.nameField.click()
        captureSheet.nameField.typeKey("a", modifierFlags: .command)
        captureSheet.nameField.typeText("Checkout")
        captureSheet.createButton.click()

        XCTAssertTrue(
            app.staticTexts["journeyEditor.name"].waitForExistence(timeout: 10),
            "Creating the journey should open it in the editor"
        )
        XCTAssertTrue(
            element(identifiedBy: "journeyStep-0").waitForExistence(timeout: 5),
            "The captured request should be the journey's first step"
        )
        XCTAssertFalse(
            element(identifiedBy: "journeyStep-1").exists,
            "One captured request is one step"
        )

        // Now the half nothing covered: appending to a journey that already exists, chosen by name
        // from the submenu.
        XCTAssertTrue(requestLogDrawer.reveal(logRow(identifiers[0])),
                      "The drawer must reveal the row before its context menu is opened")
        logRow(identifiers[0]).click()
        UITestApp.waitForStableFrame(logRow(identifiers[0]))

        // The same nested menu as above, so the same helper. There is no sheet on this path — the
        // journey already exists and picking it by name appends straight away — so the outcome
        // waited for is the second step appearing in the editor.
        let appendMenu = app.menuItems["Add to journey"]
        let appended = UITestApp.chooseFromSubmenu(
            in: app,
            parent: appendMenu,
            item: app.menuItems["Checkout"],
            thenAwait: element(identifiedBy: "journeyStep-1"),
            reopenMenu: {
                XCTAssertTrue(self.requestLogDrawer.reveal(self.logRow(identifiers[0])),
                              "The row must remain visible when reopening its context menu")
                self.logRow(identifiers[0]).rightClick()
            },
            outcomeTimeout: 10
        )
        if !appended {
            let visible = app.menuItems.allElementsBoundByIndex.prefix(8).map(\.title)
            XCTFail(
                "Appending should add a second step to the journey and show it. "
                    + "openMenus=\(app.menus.count) visibleMenuItems=\(visible) "
                    + "captureMenuPresent=\(appendMenu.exists)"
            )
        }
    }

    // MARK: - LOGSEL

    /// Selection by pointer and by keyboard, read back through the detail beside the log.
    ///
    /// One row selected shows its detail, several show the selection count, and none gives the
    /// column back to the editor and the inspector back to its fallback. The project deliberately
    /// has **no endpoints**, so that fallback is the project overview — a header title no other
    /// state shares.
    @MainActor
    func testSelectingRequestsWithTheMouseAndKeyboard() async throws {
        let port = 62108

        launchApp()
        startServer(projectNamed: "Selection Test", port: port)

        await sendRequest(port: port, path: "/api/one", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/two", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/three", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(3, timeout: 15), "All three requests should reach the log")

        let rows = visibleRows(limit: 3)
        XCTAssertEqual(rows.count, 3, "Three requests should be listed as three rows")
        let identifiers = rows.map(\.identifier)
        let labels = rows.map(\.label)

        // A row announces its own selection: the accent stripe down its leading edge is the only
        // other statement, and that is no statement at all to someone being read the panel.
        logRow(identifiers[0]).click()
        XCTAssertTrue(requestDetail.waitForDetail(), "Clicking a row should open it beside the log")
        XCTAssertTrue(
            poll { self.logRow(identifiers[0]).label.hasSuffix(", selected") },
            "A selected row should say so — it read \(logRow(identifiers[0]).label)"
        )

        // Clicking the only selected row clears it, which is how the detail gets dismissed without
        // hunting for the close button.
        // The project has no endpoints or journeys, so with the selection gone there is nothing to
        // inspect and the inspector leaves with it.
        logRow(identifiers[0]).click()
        XCTAssertTrue(
            requestDetail.path.waitForNonExistence(timeout: 5),
            "Clicking the only selected row again should clear the selection and close the detail"
        )
        XCTAssertTrue(
            inspectorHeader.waitForNonExistence(timeout: 5),
            "With nothing to inspect, the inspector should stay away once the detail closes"
        )

        // Two rows: the detail names the multi-selection instead of showing one request.
        logRow(identifiers[0]).click()
        UITestApp.waitForStableFrame(logRow(identifiers[1]))
        XCUIElement.perform(withKeyModifiers: .command) {
            logRow(identifiers[1]).click()
        }
        XCTAssertTrue(
            requestDetail.waitForMultipleSelection(),
            "With several rows selected the detail should name the selection; "
                + "rows \(identifiers.map { logRow($0).label })"
        )

        // ⌘-clicking a selected row removes it, leaving the other one showing.
        XCUIElement.perform(withKeyModifiers: .command) {
            logRow(identifiers[1]).click()
        }
        XCTAssertTrue(
            requestDetail.waitForDetail(),
            "Removing one of two selected rows should leave a single request showing"
        )
        let firstPath = try XCTUnwrap(
            ["/api/one", "/api/two", "/api/three"].first { labels[0].contains($0) },
            "A row's label should name the path it was sent to — it read \(labels[0])"
        )
        XCTAssertTrue(
            poll { self.text(of: self.requestDetail.path).contains(firstPath) },
            "The row left in the selection should be the one on screen"
        )

        // ⇧-click takes the whole run between the anchor and the clicked row. The menu's count is the
        // observable form of "three rows are selected".
        XCUIElement.perform(withKeyModifiers: .shift) {
            logRow(identifiers[2]).click()
        }
        logRow(identifiers[2]).rightClick()
        let rangeMenu = app.menuItems["Add 3 requests to journey"]
        XCTAssertTrue(
            rangeMenu.waitForExistence(timeout: 5),
            "A shift-click should extend the selection over the range between the two rows"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(rangeMenu.waitForNonExistence(timeout: 5), "Escape should dismiss the context menu")

        // The click is what hands the table keyboard focus, so it is a precondition of the presses
        // rather than part of what they are proving.
        logRow(identifiers[1]).click()
        XCTAssertTrue(requestDetail.waitForDetail(), "Clicking a row should open it beside the log")
        let beforeUp = requestDetail.shownPath()
        XCTAssertTrue(beforeUp.contains("/api/two"), "The middle row should be selected before pressing Up")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(
            poll { self.requestDetail.shownPath().contains("/api/three") },
            "The up arrow should move the selection and update the detail to the previous request"
        )

        // ⇧↓ grows the selection a row at a time, so the detail gives way to the selection count.
        app.typeKey(.downArrow, modifierFlags: .shift)
        XCTAssertTrue(
            requestDetail.waitForMultipleSelection(),
            "Shift-down should grow the selection past the one row the detail can show"
        )

        // Return collapses it back onto one row — the keyboard's "open it".
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            requestDetail.waitForDetail(),
            "Return should collapse a multi-row selection onto one row"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            inspectorHeader.waitForNonExistence(timeout: 5),
            "Escape should clear the selection, and with it the empty project's inspector"
        )
    }

    // MARK: - TRAFFIC

    /// The endpoint inspector's Traffic section counts what the endpoint answered, starting at zero.
    @MainActor
    func testEndpointTrafficSectionSummarisesWhatTheEndpointAnswered() async throws {
        let port = 62109

        launchApp()
        // After the launch: `app` is created by it, and building the page first unwrapped nil.
        let inspector = InspectorPage(app: app)
        startServer(projectNamed: "Traffic Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        XCTAssertTrue(inspector.traffic.waitForExistence(timeout: 5), "A selected endpoint should show its traffic")
        XCTAssertTrue(inspector.trafficServed.waitForExistence(timeout: 5),
                      "An endpoint nothing has called should still show its figures")
        XCTAssertTrue(
            poll { self.speech(of: inspector.trafficServed).contains("0") },
            "Nothing has been served yet — it read \(speech(of: inspector.trafficServed))"
        )

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(3, timeout: 15), "All three requests should reach the log")

        // Only the endpoint's own two calls are counted; the unmatched /api/orders is not its traffic.
        XCTAssertTrue(inspector.trafficServed.waitForExistence(timeout: 10), "The section should count what was served")
        XCTAssertTrue(
            poll { self.speech(of: inspector.trafficServed).contains("2") },
            "Served should count the endpoint's two calls — it read \(speech(of: inspector.trafficServed))"
        )
        XCTAssertTrue(
            poll { self.speech(of: inspector.trafficErrors).contains("0") },
            "Nothing failed — errors read \(speech(of: inspector.trafficErrors))"
        )
    }
}

/// A real, test-owned upstream. No production hooks and no external network.
nonisolated private final class PassthroughUIBackend: @unchecked Sendable {
    private let listener: NWListener
    init(port: UInt16, ready: @escaping @Sendable () -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { if case .ready = $0 { ready() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "mimic.ui.backend.connection"))
            Self.receive(connection, bytes: Data())
        }
        listener.start(queue: DispatchQueue(label: "mimic.ui.backend.listener"))
    }
    func stop() { listener.cancel() }
    private static func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var request = bytes
            if let data { request.append(data) }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil || request.count > 65536 { connection.cancel() }
                else { receive(connection, bytes: request) }
                return
            }
            let binary = String(decoding: request, as: UTF8.self).hasPrefix("GET /binary ")
            let body = binary ? Data([0x89, 0x50, 0x4E, 0x47, 0xFF]) : Data(#"{"account":"Ada"}"#.utf8)
            let type = binary ? "image/png" : "application/json"
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            reply.append(body)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
