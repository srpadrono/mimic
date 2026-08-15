import Foundation
import XCTest

/// The request log's own suite: sorting, filtering, selection, the row context menu, the request
/// detail inspector, and the inspector's Traffic tab.
///
/// It sits beside `MimicUITests` rather than inside it because that file is already 1,800 lines and
/// its page objects are file-scope — so this suite **reuses** `RequestLogDrawerPage`,
/// `RequestDetailPage`, `WorkspacePage` and `CaptureJourneySheetPage` through `MimicUITestCase`
/// instead of declaring a second set of queries for the same panel.
///
/// Three rules from `mimic-ui-tests` shape almost every query below, and each one has already cost
/// this suite time:
///
/// - **A leaf inside `DSPanelHeader`, `DSTabStrip` or `DSEmptyState` loses its own identifier.** The
///   drawer's clear button, method filter, filter field and unmatched toggle all live in
///   `DSPanelHeader("Request log", identifier: "requestLog")`, and the inspector's Traffic tab is a
///   `DSTabStrip` button inside a `DSPanelHeader` — doubly flattened. Those are matched by **label**.
///   `RequestLogDrawerPage.clearButton` queries `clearRequestLogButton`, which is exactly the
///   identifier the header stamps over, so this file does not use it.
/// - **The table header is a plain `HStack`, so its six `drawer.columnHeader.<field>` identifiers do
///   survive** — and each carries the sort direction in its `accessibilityValue` rather than its
///   label, which is what ``sortState(of:)`` reads.
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

    /// For a control whose identifier has two possible spellings — a `DSMethodBadge` prefixes the
    /// name it is handed, so the request line's badge is either `requestDetail.method` or
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
    /// `DSEmptyState`'s heading arrives as the value, a `DSStatusPill`'s code as the label — and the
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
    /// holds reads as empty while the string it is asserting on is one level down. The traffic
    /// header's status chip is the case that proved it — `endpointTraffic.status.200` resolved, and
    /// its `label` was "". Reading the subtree is what makes an assertion about what a control says
    /// independent of how SwiftUI split it up.
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

    // MARK: - Drawer chrome, matched by label

    /// The trash button in the drawer's header. Label, not `clearRequestLogButton`: it is a
    /// `DSPanelHeaderButton` inside `DSPanelHeader`, whose identifier wins over its children's.
    /// `DSPanelHeaderButton` speaks its `help` string as the label.
    @MainActor
    private var clearLogButton: XCUIElement { app.buttons["Clear request log"].firstMatch }

    /// The method popup, likewise flattened. Tried as a pop-up button first and then as any element
    /// with the label, for the reason `RequestDetailPage.tab(_:)` gives: the realization is a style
    /// detail and a query pinned to it breaks silently.
    @MainActor
    private var methodFilterControl: XCUIElement {
        let byPopUp = app.popUpButtons["Filter by method"].firstMatch
        if byPopUp.exists { return byPopUp }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Filter by method"))
            .firstMatch
    }

    /// The text filter. Its identifier may or may not survive the header — a plain `TextField` is not
    /// a `DSTextField` lending its name to one control — so both handles are polled together.
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

    /// The unmatched-only toggle. Its label carries the count ("…, 3 so far"), so this matches on the
    /// stable prefix rather than on a string that moves with the traffic.
    @MainActor
    private var unmatchedToggle: XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Show only unmatched requests"))
            .firstMatch
    }

    /// The drawer header's count, which rides in `DSPanelHeader`'s subtitle slot and reports the
    /// container's identifier rather than its own — the same flattening `RequestDetailPage.panelTitle`
    /// documents, so it is matched the same way: identifier **plus** the text.
    ///
    /// Three identifiers are accepted — the container's, the subtitle's own, and none at all — because
    /// which of them a flattened leaf ends up carrying is a SwiftUI detail that has already changed
    /// once. The text is what makes the match specific: "2 requests" is the drawer subtitle's exact
    /// wording, and nothing else on screen in these tests spells a count that way (the inspector's
    /// overview writes "Requests" and "2" as a label/value pair).
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

    // MARK: - Traffic tab

    /// The inspector's Traffic tab. Unreachable by identifier — `DSTabStrip` stamps
    /// `ds.tabstrip.inspector` on every tab and the surrounding `DSPanelHeader` flattens again — so
    /// this matches the tab's help text, which `DSTabStrip` uses as the button's label.
    @MainActor
    private var trafficTab: XCUIElement {
        app.buttons["Show the requests this endpoint answered"].firstMatch
    }

    // MARK: - Shared arrangement

    /// Opens a project on `port` and starts the server, so the log has somewhere to come from.
    @MainActor
    private func startServer(projectNamed name: String, port: Int) {
        createProjectViaUI(name: name, port: port)
        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "The server should report its base URL once running"
        )
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

        // Endpoint and Scenario have no order worth asserting on three rows — two of them are
        // unmatched and share an empty key — so these two assert the state the header reports, which
        // is what a reader of the panel gets.
        sort(by: "endpoint", expecting: "sorted ascending")
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

    /// The filter field's three predicates — path, status code, outcome word — the method popup, and
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
            "'No requests yet' is a different state — the log still holds three entries"
        )

        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitForVisibleRowCount(3), "Clearing the filter should bring every row back")

        // The method popup. Its identifier is stamped over by the panel header, so it is reached by
        // label; its items are ordinary menu elements once it is open.
        XCTAssertTrue(methodFilterControl.waitForExistence(timeout: 5), "The method filter should be addressable")
        methodFilterControl.click()
        let postItem = app.menuItems["POST"]
        XCTAssertTrue(postItem.waitForExistence(timeout: 5), "The method popup should offer POST")
        postItem.click()

        XCTAssertTrue(waitForVisibleRowCount(1), "Filtering by POST should leave the one POST")
        XCTAssertTrue(
            poll { self.firstRowLabel().hasPrefix("POST ") },
            "The surviving row should be the POST — it was \(firstRowLabel())"
        )

        methodFilterControl.click()
        let allItem = app.menuItems["All"]
        XCTAssertTrue(allItem.waitForExistence(timeout: 5), "The method popup should offer All")
        allItem.click()
        XCTAssertTrue(waitForVisibleRowCount(3), "Choosing All should clear the method filter")
    }

    // MARK: - LOGFILT (unmatched) and clearing the log

    /// The unmatched-only toggle — inert while nothing is unmatched, counted once something is — the
    /// toolbar badge that switches it on from outside the panel, and the trash button that empties
    /// the log.
    @MainActor
    func testUnmatchedOnlyFilterAndClearingTheLog() async throws {
        let port = 62103

        launchApp()
        startServer(projectNamed: "Unmatched Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(1, timeout: 15), "The matched request should reach the log")

        // Nothing to filter to and not already filtering: the control is disabled, and it says so
        // rather than sitting there looking pressable.
        XCTAssertTrue(unmatchedToggle.waitForExistence(timeout: 5), "The unmatched filter should be in the header")
        XCTAssertEqual(
            unmatchedToggle.label,
            "Show only unmatched requests",
            "With nothing unmatched the toggle should carry no count"
        )
        XCTAssertFalse(unmatchedToggle.isEnabled, "The unmatched filter should be inert while nothing is unmatched")

        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "The unmatched request should reach the log")

        XCTAssertTrue(
            poll { self.unmatchedToggle.label == "Show only unmatched requests, 1 so far" },
            "The toggle should carry the count — it read \(unmatchedToggle.label)"
        )
        XCTAssertTrue(unmatchedToggle.isEnabled, "The unmatched filter should come alive once there is one to find")

        // The toolbar's badge is the other way in: it opens the drawer already filtered, the way
        // Xcode's warning count jumps you to the issue navigator.
        let toolbarBadge = app.buttons["1 unmatched request, show it"].firstMatch
        XCTAssertTrue(toolbarBadge.waitForExistence(timeout: 5), "The status well should badge the unmatched call")
        toolbarBadge.click()
        XCTAssertTrue(waitForVisibleRowCount(1), "The badge should filter the log down to the unmatched call")
        XCTAssertTrue(
            poll { self.firstRowLabel().contains("unmatched") },
            "The surviving row should be the unmatched one — it was \(firstRowLabel())"
        )

        // Off, then on again, from the panel's own control.
        unmatchedToggle.click()
        XCTAssertTrue(waitForVisibleRowCount(2), "Turning the unmatched filter off should bring the full log back")
        unmatchedToggle.click()
        XCTAssertTrue(waitForVisibleRowCount(1), "Turning it back on should narrow to the unmatched call again")

        // Clearing empties the log outright, and the panel falls back to its idle state — not to the
        // "No matching requests" one, which would be a filter still claiming to be filtering.
        XCTAssertTrue(clearLogButton.waitForExistence(timeout: 5), "The header should offer a clear button")
        clearLogButton.click()

        // Two assertions, in this order, because they fail for different reasons: the rows going is
        // the clear having happened at all, and the empty state is what the panel does about it.
        XCTAssertTrue(waitForVisibleRowCount(0), "The trash button should empty the log")

        // `RequestLogDrawerView` checks `requestLogs.isEmpty` before it checks the filter, so a
        // cleared log shows "No requests yet" even with the unmatched filter still on. The heading is
        // a `DSEmptyState` leaf, so it is reached the way this file reaches the "No matching requests"
        // one: the plain label first, then the identifiers the component builds — the container's and
        // the heading's — polled together rather than waited out in turn. `emptyHeading` alone is a
        // label match on a leaf whose string arrives in `value` as readily as in `label`, which is why
        // it went unfound here while the same query answers on a log that was never written to.
        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    requestLogDrawer.emptyHeading,
                    element(identifiedBy: "ds.empty.drawer.requests.heading"),
                    element(identifiedBy: "ds.empty.drawer.requests"),
                ],
                timeout: 5
            ),
            "Clearing the log should restore the 'No requests yet' empty state"
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

    /// What a row says out loud, what the header counts, and the two tabs of the request detail that
    /// no test has opened: Summary and Headers.
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

        // The six columns exist only inside the composed label, so this is the assertion that the
        // method badge, path, endpoint, scenario and status pill are saying the right things.
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
            "An unmatched row should say so rather than leaving the endpoint column silent — it read \(unmatchedLabel)"
        )

        let matchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/users"), "The matched row should be addressable")
        logRow(matchedID).click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Clicking a row should switch the inspector to request detail"
        )

        // The identity line: badge, status pill and time. `DSMethodBadge` prefixes the identifier it
        // is handed, so both spellings are matched.
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

        // Summary is the tab a selection opens on.
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.answeredBy").waitForExistence(timeout: 5),
            "The Summary tab should head its first section 'Answered by'"
        )
        let outcomeRow = element(identifiedBy: "requestDetail.summary.outcome")
        XCTAssertTrue(outcomeRow.waitForExistence(timeout: 5), "Summary should state the outcome")
        XCTAssertTrue(
            text(of: outcomeRow).localizedCaseInsensitiveContains("endpoint"),
            "An endpoint answered this call — the row read \(text(of: outcomeRow))"
        )
        XCTAssertTrue(
            text(of: element(identifiedBy: "requestDetail.summary.endpoint")).contains("Users"),
            "Summary should name the endpoint that answered"
        )
        XCTAssertTrue(
            text(of: element(identifiedBy: "requestDetail.summary.scenario")).contains("Default"),
            "Summary should name the scenario that answered"
        )

        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.sizes").waitForExistence(timeout: 5),
            "The Summary tab should head its second section 'Sizes'"
        )
        for row in ["request body", "response body", "request headers", "response headers"] {
            XCTAssertTrue(
                element(identifiedBy: "requestDetail.summary.\(row)").exists,
                "Summary should report the \(row)"
            )
        }

        // Headers.
        requestDetail.tab("Headers").click()
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.headers.request").waitForExistence(timeout: 5),
            "The Headers tab should head the request half"
        )
        XCTAssertTrue(
            element(identifiedBy: "ds.sectionheader.requestDetail.headers.response").exists,
            "The Headers tab should head the response half, naming what answered"
        )

        // Assert on the rows rather than only on the section titles — and pair each count with the
        // absence of that section's empty note, because "no headers" renders under the same prefix.
        XCTAssertFalse(
            element(identifiedBy: "requestDetail.headers.request.empty").exists,
            "A request carrying headers should not show the empty note"
        )
        XCTAssertTrue(
            poll { self.elements(identifierPrefix: "requestDetail.headers.request.").count > 0 },
            "The request headers the client actually sent should be listed"
        )
        XCTAssertFalse(
            element(identifiedBy: "requestDetail.headers.response.empty").exists,
            "An answered request should not show the no-response note"
        )
        XCTAssertTrue(
            elements(identifierPrefix: "requestDetail.headers.response.").count > 0,
            "The response headers the client received should be listed"
        )

        // And back — the tab is a segmented picker, so this is a different control from the close
        // button that leaves request detail altogether.
        requestDetail.tab("Summary").click()
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.summary.outcome").waitForExistence(timeout: 5),
            "Switching back to Summary should show the answered-by rows again"
        )
    }

    // MARK: - REQDET body tab and copy bar

    /// The Body tab across the two shapes a logged exchange actually takes — a matched call whose
    /// default scenario returns nothing, and an unmatched one whose body is Mimic's own fallback —
    /// plus the find field's zero-match state, its clear button, and the two copy buttons no test
    /// has clicked.
    @MainActor
    func testRequestDetailBodyTabAndCopyButtons() async throws {
        let port = 62105
        let payload = #"{"name":"Ada Lovelace","role":"engineer"}"#

        launchApp()
        startServer(projectNamed: "Body Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users", method: "POST")

        await sendRequest(port: port, path: "/api/users", method: "POST", body: payload)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "Both requests should reach the log")

        let matchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/users"), "The matched row should be addressable")
        let unmatchedID = try XCTUnwrap(rowIdentifier(forPath: "/api/orders"), "The unmatched row should be addressable")

        logRow(matchedID).click()
        XCTAssertTrue(requestDetail.waitForPanelTitle("Request"), "The inspector should show the clicked request")
        requestDetail.tab("Body").click()

        // A new endpoint's default scenario has no body, so this is the empty arm — the one a reader
        // meets most often and which nothing covered.
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.body.response.empty").waitForExistence(timeout: 5),
            "A scenario with no body should say 'No response body' rather than rendering nothing"
        )
        XCTAssertTrue(
            element(identifiedBy: "requestLog.body.request").waitForExistence(timeout: 5),
            "The POST payload should be rendered in the request half"
        )

        // Copy Response is gated on there being one.
        let copyResponse = element(identifiedBy: "requestDetail.copy.responseBody")
        XCTAssertTrue(copyResponse.waitForExistence(timeout: 5), "The copy bar should offer Response")
        XCTAssertFalse(copyResponse.isEnabled, "Copy Response should be disabled when the response carried no body")

        let copyAll = element(identifiedBy: "requestDetail.copy.all")
        XCTAssertTrue(copyAll.waitForExistence(timeout: 5), "The copy bar should offer All")
        copyAll.click()
        XCTAssertTrue(
            poll { self.text(of: self.requestDetail.copyConfirmation).localizedCaseInsensitiveContains("all") },
            "Copying everything should confirm it happened"
        )

        // A term the payload does not contain is an answer, not a failed search.
        let search = requestDetail.bodySearchField
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The Body tab should offer a find field")
        search.click()
        search.typeText("zzzznothing")
        let requestMatches = element(identifiedBy: "requestLog.body.request.matches")
        XCTAssertTrue(
            poll { self.text(of: requestMatches).contains("No matches in this body") },
            "A term the body does not contain should be reported, not left silent"
        )

        // The find field's own clear button — a `DSClearButton`, which applies the identifier it is
        // handed verbatim and sits outside any flattening container.
        let clearSearch = element(identifiedBy: "requestDetail.clearBodySearch")
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 5), "A non-empty find field should offer a clear button")
        clearSearch.click()
        XCTAssertTrue(
            poll { requestMatches.exists == false },
            "Clearing the search should take the match count with it"
        )

        search.click()
        search.typeText("Lovelace")
        XCTAssertTrue(
            poll { self.text(of: requestMatches).contains("1 match") },
            "The find field should count the hits in the body"
        )

        // Selecting another request drops the term — carrying a search for a payload you are no
        // longer looking at is the case `onChange(of: log.id)` exists for.
        logRow(unmatchedID).click()
        XCTAssertTrue(
            poll { requestMatches.exists == false },
            "Selecting a different request should reset the body search"
        )

        // The unmatched call is the mirror image: no request body, and a response body Mimic wrote.
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.body.request.empty").waitForExistence(timeout: 5),
            "A GET with no payload should say 'No request body'"
        )
        XCTAssertTrue(
            element(identifiedBy: "requestLog.body.response").waitForExistence(timeout: 5),
            "The fallback response body should be rendered"
        )

        let copyResponseAgain = element(identifiedBy: "requestDetail.copy.responseBody")
        XCTAssertTrue(
            poll { copyResponseAgain.isEnabled },
            "Copy Response should be live once there is a body to copy"
        )
        copyResponseAgain.click()
        XCTAssertTrue(
            poll { self.text(of: self.requestDetail.copyConfirmation).localizedCaseInsensitiveContains("response") },
            "Copying the response should confirm it happened"
        )

        // The hint that explains what an unmatched request is and what to do about it.
        requestDetail.tab("Summary").click()
        XCTAssertTrue(
            element(identifiedBy: "requestDetail.unmatchedHint").waitForExistence(timeout: 5),
            "An unmatched request should explain that Mimic answered with its fallback"
        )
        XCTAssertTrue(
            text(of: element(identifiedBy: "requestDetail.summary.outcome"))
                .localizedCaseInsensitiveContains("unmatched"),
            "Summary should state the unmatched outcome"
        )
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
        await sendRequest(port: port, path: "/api/items", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(3, timeout: 15), "All three requests should reach the log")

        let rows = visibleRows(limit: 3)
        XCTAssertEqual(rows.count, 3, "Three requests should be listed as three rows")
        let identifiers = rows.map(\.identifier)

        // Two rows selected, then a right-click on the third — which is *outside* the selection, so
        // the menu must act on the clicked row alone rather than on rows the pointer is nowhere near.
        logRow(identifiers[0]).click()
        XCUIElement.perform(withKeyModifiers: .command) {
            logRow(identifiers[1]).click()
        }
        logRow(identifiers[2]).rightClick()

        let singularMenu = app.menuItems["Add to journey"]
        XCTAssertTrue(
            singularMenu.waitForExistence(timeout: 5),
            "A right-click outside the selection should offer to capture that one row"
        )
        XCTAssertFalse(
            app.menuItems["Add 2 requests to journey"].exists,
            "The menu must not act on a selection the clicked row is not part of"
        )

        singularMenu.click()
        let newJourneyItem = app.menuItems["New journey from this request\u{2026}"]
        XCTAssertTrue(
            newJourneyItem.waitForExistence(timeout: 5),
            "The submenu should offer a new journey for the single request"
        )
        newJourneyItem.click()

        XCTAssertTrue(
            captureSheet.nameField.waitForExistence(timeout: 5),
            "Capturing into a new journey should ask for a name first"
        )
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
        logRow(identifiers[0]).click()
        logRow(identifiers[0]).rightClick()
        let appendMenu = app.menuItems["Add to journey"]
        XCTAssertTrue(appendMenu.waitForExistence(timeout: 5), "The row should still offer the capture menu")
        appendMenu.click()

        let existingJourney = app.menuItems["Checkout"]
        XCTAssertTrue(
            existingJourney.waitForExistence(timeout: 5),
            "The submenu should list the journey that now exists"
        )
        existingJourney.click()

        XCTAssertTrue(
            element(identifiedBy: "journeyStep-1").waitForExistence(timeout: 10),
            "Appending should add a second step to the journey and show it"
        )
    }

    // MARK: - LOGSEL

    /// Selection by pointer and by keyboard, read back through the inspector.
    ///
    /// The project deliberately has **no endpoints**: with none, the inspector's fallback is the
    /// project overview, so "one row selected" and "no useful selection" are two different header
    /// titles — "Request" and "Overview" — rather than two states that both read "Scenarios". That is
    /// what makes every assertion below observable without a single new identifier.
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
        XCTAssertTrue(requestDetail.waitForPanelTitle("Request"), "Clicking a row should show it in the inspector")
        XCTAssertTrue(
            poll { self.logRow(identifiers[0]).label.hasSuffix(", selected") },
            "A selected row should say so — it read \(logRow(identifiers[0]).label)"
        )

        // Clicking the only selected row clears it, which is how the detail gets dismissed without
        // hunting for the close button.
        logRow(identifiers[0]).click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "Clicking the only selected row again should clear the selection"
        )

        // Two rows: the inspector cannot claim to describe a selection it is a fraction of.
        logRow(identifiers[0]).click()
        XCUIElement.perform(withKeyModifiers: .command) {
            logRow(identifiers[1]).click()
        }
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "With several rows selected the inspector should fall back to the overview"
        )

        // ⌘-clicking a selected row removes it, leaving the other one showing.
        XCUIElement.perform(withKeyModifiers: .command) {
            logRow(identifiers[1]).click()
        }
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
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
        XCTAssertTrue(requestDetail.waitForPanelTitle("Request"), "Clicking a row should show it in the inspector")
        let beforeUp = requestDetail.shownPath()
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(
            poll { self.requestDetail.shownPath() != beforeUp },
            "The up arrow should move the selection to the previous row"
        )

        // ⇧↓ grows the selection a row at a time, so the inspector leaves request mode again.
        app.typeKey(.downArrow, modifierFlags: .shift)
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "Shift-down should grow the selection past the one row the inspector can show"
        )

        // Return collapses it back onto one row — the keyboard's "open it".
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Return should collapse a multi-row selection onto one row"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "Escape should clear the selection"
        )
    }

    // MARK: - TRAFFIC

    /// The inspector's second tab for a selected endpoint: what has actually called it.
    ///
    /// The tab itself is unreachable by identifier — a `DSTabStrip` button inside a `DSPanelHeader`,
    /// flattened twice — so it is clicked by its help text, and the badge count is read from the same
    /// element's value, which is the only place the dot's number is stated.
    @MainActor
    func testEndpointTrafficTabListsWhatTheEndpointAnswered() async throws {
        let port = 62109

        launchApp()
        startServer(projectNamed: "Traffic Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        XCTAssertTrue(trafficTab.waitForExistence(timeout: 5), "A selected endpoint should offer a Traffic tab")
        trafficTab.click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Traffic"),
            "The header should follow the tab — it is the more specific answer to what the panel is showing"
        )
        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    app.staticTexts["No traffic yet"],
                    element(identifiedBy: "ds.empty.endpointTraffic.empty.heading"),
                    element(identifiedBy: "ds.empty.endpointTraffic.empty"),
                ],
                timeout: 5
            ),
            "An endpoint nothing has called should say so"
        )

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        XCTAssertTrue(waitForRowsToArrive(2, timeout: 15), "Both requests should reach the log")

        // The summary line, which is the panel's own header rather than a row.
        let summary = element(identifiedBy: "endpointTraffic.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "The traffic list should summarise what it holds")
        XCTAssertTrue(
            poll { self.text(of: summary).contains("2 requests") },
            "The summary should count the endpoint's traffic — it read \(text(of: summary))"
        )

        // The distribution chip: one per status code seen, with how often.
        //
        // Read as a subtree, not as one element's label. `DSStatusPill` sets no accessibility of its
        // own — identifiers and labels are the call site's — and `EndpointTrafficList` gives this one
        // both an identifier and an `.accessibilityLabel("2 responses with status 200")`; what
        // arrives is an element carrying the identifier with an **empty** label, so the strict
        // `chip.label ==` read this replaces asserted against "". The words are in the subtree, in
        // one of the two spellings the chip legitimately has: the spoken label, or the pill's own
        // "200 ×2". Either states the same fact — this code, this many — so both are accepted, and
        // the assertion still fails on a chip that names the code without the count.
        let statusChip = element(identifiedBy: "endpointTraffic.status.200")
        XCTAssertTrue(statusChip.waitForExistence(timeout: 5), "The status mix should include the 200s")
        XCTAssertTrue(
            poll {
                let spoken = self.speech(of: statusChip)
                return spoken.contains("200")
                    && (spoken.contains("2 responses") || spoken.contains("\u{00D7}2"))
            },
            "The chip should say how many responses carried the code — it read \(speech(of: statusChip))"
        )

        // The badge rides the tab as a dot, so the count exists only in the tab's value.
        XCTAssertTrue(
            poll { self.text(of: self.trafficTab).contains("2") },
            "The tab should announce how many requests it has to show — it read \(text(of: trafficTab))"
        )

        // A row: status, time and head-truncated path, composed into one spoken label because the row
        // is `.ignore`d and its cells cannot exist as elements.
        //
        // The composed label is the second handle, and it is unambiguous: the request log's row for
        // the same call says more ("…, endpoint Users, scenario Default"), so an exact-label match
        // cannot resolve to the drawer by mistake.
        let trafficRow = try XCTUnwrap(
            firstExisting([
                elements(identifierPrefix: "endpointTraffic.row.").firstMatch,
                app.buttons["GET /api/users, status 200"].firstMatch,
            ]),
            "The endpoint's requests should be listed as rows"
        )
        XCTAssertTrue(
            trafficRow.label.contains("GET /api/users") && trafficRow.label.contains("status 200"),
            "A traffic row should announce the request and what came back — it read \(trafficRow.label)"
        )

        // Clicking one opens it in the request detail, which is the whole point of listing them here.
        trafficRow.click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Clicking a traffic row should open that request in the detail inspector"
        )
        XCTAssertTrue(
            poll { self.text(of: self.requestDetail.path).contains("/api/users") },
            "The detail should be showing the request that was clicked"
        )
    }
}
