import AppKit
import Carbon
import Foundation
import XCTest

/// Getting a macOS app to the foreground reliably enough to drive it.
///
/// `XCUIApplication.launch()` returns once the process is running, which is not the same as having a
/// window the accessibility layer can see: the app may come up hidden, behind the test runner, or
/// with its window not yet realized. The original suite grew an activation retry to cope, while the
/// journeys suite launched and asserted immediately — and failed every test on "Welcome screen
/// should appear". This is that logic in one place, so a suite cannot be written without it.
enum UITestApp {

    static let bundleIdentifier = "devxa.Mimic"

    /// The environment key both halves of the discovery-file contract resolve. Spelled here because
    /// this target links no `Domain` — the one declaration is
    /// `ControlEndpointDiscovery.pathEnvironmentKey`.
    static let controlFileEnvironmentKey = "MIMIC_CONTROL_FILE"

    /// Where an app launched by this run advertises its control plane: a per-run sidecar, never the
    /// shared `control.json`.
    ///
    /// The app starts the control plane on every launch, and on every successful bind it writes the
    /// advertisement — port, pid, and the `X-Mimic-Token` credential — wherever `MIMIC_CONTROL_FILE`
    /// points, then removes that file on shutdown. Both halves resolve the override through
    /// `ControlEndpointDiscovery.overrideURL`, so exporting the variable is the whole isolation.
    /// Without it, every UI launch overwrote the developer's live advertisement with the test
    /// instance's token, and every teardown deleted it — leaving a still-running Mimic that no
    /// `mimic` command could discover until relaunch. That is the `mimic.sqlite` failure class
    /// applied to credential material, which is why the export lives in the one launch path every
    /// suite goes through (UI DoD rule 6) rather than in each suite's environment block, where it
    /// would be one forgotten line away from recurring.
    ///
    /// Tilde-relative on purpose: the app is sandboxed, so *it* expands `~` into its container and
    /// the file lands beside `mimic-uitests.sqlite`, where the app can actually write — the same
    /// reasoning `UITestSupport.databaseURL` records for the store. The name is the guard, as with
    /// that store: whatever directory this resolves into, a file not called `control.json` can never
    /// be the shared advertisement. The runner's pid keeps a file left behind by a crashed run from
    /// describing this one.
    static let controlFileOverridePath = "~/Library/Application Support/devxa.Mimic/"
        + "mimic-uitests-control-\(ProcessInfo.processInfo.processIdentifier).json"

    /// Exports an isolated discovery file and ephemeral control port unless a suite supplied its
    /// own. The file avoids overwriting the developer's token; port 0 avoids binding their 8787.
    @MainActor
    static func isolateControlPlaneDiscovery(for app: XCUIApplication) {
        if app.launchEnvironment[controlFileEnvironmentKey] == nil {
            app.launchEnvironment[controlFileEnvironmentKey] = controlFileOverridePath
        }
        if app.launchEnvironment["MIMIC_CONTROL_PORT"] == nil {
            app.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
        }
    }

    /// The app container keeps its discovery file private, so find the ephemeral listener owned by
    /// the process this test launched. Call before starting a mock server in that process.
    static func listeningLoopbackPort(of pid: pid_t) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        for line in lines {
            guard let range = line.range(of: "TCP 127.0.0.1:") else { continue }
            let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
            if let port = Int(digits), port > 0 { return port }
        }
        return nil
    }

    /// Waits for a condition, polling until it holds or the deadline passes, and returns the last
    /// evaluation.
    ///
    /// Preferred over a fixed pause, which is wrong in both directions: too short and the test is
    /// flaky, too long and every run pays for it. Polling returns the moment the condition is true
    /// and still fails within a bounded time when it never becomes true. It looks once before any
    /// pause, so a condition that already holds costs one evaluation, and a `timeout` of 0 is a
    /// single look.
    ///
    /// **Between looks the run loop turns; the thread does not just sleep.** XCTest's waits run the
    /// current run loop while they wait (its headers say so of `waitForExpectations`), and
    /// `waitToExist`/`waitToDisappear`, which replaced them across the suite, come through here.
    /// Anything queued on the main thread while a test waits, such as a main-actor continuation or a
    /// callback XCTest delivers there, therefore still runs during the wait, as it did inside XCTest's.
    /// Off the main thread a run loop usually has nothing to run and returns at once; the sleep below
    /// keeps the poll a poll there.
    @discardableResult
    static func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if CFRunLoopRunInMode(.defaultMode, pollInterval, false) == .finished {
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        return condition()
    }

    /// Waits until any one of `elements` exists, polling all of them together.
    ///
    /// Prefer this over `a.waitToExist(t) || b.waitToExist(t)`. That form waits out `a`'s
    /// *entire* timeout before it ever looks at `b`, so a short-lived `b` can appear and disappear
    /// inside `a`'s wait — the test then fails reporting that neither was seen, when in fact one was
    /// on screen the whole time. That is precisely how the autosave assertion failed: `.saving` lasts
    /// only as long as a SQLite write, and the six seconds spent waiting for it outlived the two
    /// seconds `.saved` stays up.
    @MainActor
    static func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { elements.contains { $0.exists } }
    }

    // MARK: - Menus

    /// Local macOS exposes the menu name as AX title; CI macOS reports an empty title. Require the
    /// exact name in title or label on the actionable menu button, never only on a child image.
    @MainActor
    static func assertAccessibleMenuName(
        _ menu: XCUIElement,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let title = menu.title
        let label = menu.label
        XCTContext.runActivity(
            named: "Menu AX name '\(expected)': title '\(title)', label '\(label)'"
        ) { _ in }
        guard title == expected || label == expected else {
            XCTFail(
                "Expected menu name '\(expected)'; AX title '\(title)', label '\(label)'. \(menu.debugDescription)",
                file: file,
                line: line
            )
            return
        }
    }

    /// Waits until `element` reports the same non-empty frame twice in a row.
    ///
    /// `waitToExist` answers "is it in the accessibility tree", which for an AppKit menu happens
    /// when the menu is *created* — before it has been positioned and while it is still fading in. A
    /// `click()` in that window computes a frame that is about to change and synthesizes the event at
    /// coordinates the item has already left, so the click lands on the menu's backdrop, the menu
    /// closes, and nothing happens. Nothing about that reads as a missed click afterwards: the test
    /// simply waits out its timeout for a sheet nobody asked for.
    ///
    /// Two equal readings a poll apart is the cheapest statement of "it has stopped moving". It is a
    /// heuristic and worth naming as one — a frame that pauses mid-animation for a whole poll would
    /// satisfy it — but it is a far better one than a fixed pause, which this file may not use and
    /// would be wrong in both directions anyway.
    ///
    /// `snapshot()` rather than `.frame`: reading `.frame` on an element that has just gone away
    /// raises an XCTest failure, and every suite here runs with `continueAfterFailure = false`, so a
    /// menu that closed underneath this helper would end the test rather than let the caller retry.
    /// `try?` turns that into "no reading yet".
    ///
    /// Returns the frame the two readings agreed on, or `nil` when they never did, so a caller that
    /// needs a point to click or a size to compare takes it from the readings that proved it still.
    @MainActor
    @discardableResult
    static func waitForStableFrame(_ element: XCUIElement, timeout: TimeInterval = 2) -> CGRect? {
        var previous: CGRect?
        var settled: CGRect?
        _ = waitUntil(timeout: timeout, pollInterval: 0.1) {
            let current = (try? element.snapshot())?.frame
            defer { previous = current }
            guard let current, current.width > 0, current.height > 0, current == previous else { return false }
            settled = current
            return true
        }
        return settled
    }

    /// What an element is called and where it is, as one string for an activity or a failure
    /// message. Read through a snapshot, so an element that is not in the tree is described as such
    /// rather than failing the test on the read.
    @MainActor
    static func describe(_ element: XCUIElement) -> String {
        guard let snapshot = try? element.snapshot() else { return "<not in the tree>" }
        let name = snapshot.identifier.isEmpty ? snapshot.label : snapshot.identifier
        return "'\(name)' at \(snapshot.frame)"
    }

    /// Everything an element says, label and value, read the same way as ``describe(_:)``.
    @MainActor
    static func spoken(_ element: XCUIElement) -> String {
        guard let snapshot = try? element.snapshot() else { return "<not in the tree>" }
        let value = snapshot.value.map { String(describing: $0) } ?? ""
        return "\(snapshot.label) \(value)".trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Clicks that open something

    /// Clicks `element` to open something, a sheet, a menu or a popover, and returns once `opened`
    /// holds.
    ///
    /// A bare `click()` the moment an element enters the tree is how "The step sheet should open"
    /// failed on CI with nothing to say why: "Add step" was in the tree, but CI's always-visible
    /// scroll bar lay across it, so the click went to the scroller. This waits for what a person's
    /// click needs first, the element in the tree, under the pointer and not moving, then clicks once
    /// and watches for the outcome.
    ///
    /// **Hittability is waited for, not required.** `isHittable` has said no about a control a click
    /// then reached (the note at the click in `JourneyEditorUITests.testStepsEmptyStateAddsTheFirstStep`),
    /// so one that never becomes hittable is still clicked and the outcome decides. The result
    /// bundle records that it was not hittable and where it was, which is the first question such a
    /// failure raises.
    ///
    /// **Only for clicks that open something.** A second click on a toggle undoes the first, so a
    /// retry could turn a missed click into a pass for the wrong reason. A sheet or a menu that has
    /// visibly not opened is safe to ask for again, and `opened` is checked once more just before
    /// the second click, so an open that was only slow is not clicked shut. A retry is recorded as an
    /// activity, so a pass on the second click shows in the result bundle instead of passing quietly.
    ///
    /// Returns whether `opened` ever held, so the caller asserts with its own message.
    @MainActor
    @discardableResult
    static func click(
        _ element: XCUIElement,
        expecting opened: () -> Bool,
        attempts: Int = 2,
        timeout: TimeInterval = 5
    ) -> Bool {
        let rounds = max(1, attempts)
        for attempt in 1...rounds {
            if attempt > 1 {
                if opened() { return true }
                XCTContext.runActivity(
                    named: "The click on \(describe(element)) opened nothing; clicking again "
                        + "(attempt \(attempt) of \(rounds))"
                ) { _ in }
            }
            guard element.waitToExist(timeout: timeout) else {
                XCTContext.runActivity(named: "Nothing to click: the element never appeared") { _ in }
                return opened()
            }
            if !waitUntil(timeout: 2, pollInterval: 0.1, { element.exists && element.isHittable }) {
                XCTContext.runActivity(named: "\(describe(element)) is not hittable; clicking it anyway") { _ in }
            }
            waitForStableFrame(element)
            element.click()
            // The full clock only on the last click, as in `chooseFromSubmenu`: a missed click is
            // found out quickly and a slow open is still waited out.
            let wait = attempt == rounds ? timeout : min(timeout, 3)
            if waitUntil(timeout: wait, pollInterval: 0.1, opened) { return true }
        }
        return false
    }

    /// Closes whatever menu is open, including a submenu, and returns once none is.
    ///
    /// `app.menus` counts open `AXMenu` elements and does not include the menu bar, so this is "is a
    /// menu on screen" rather than "does the app have menus". One Escape closes one level, which is
    /// why this loops.
    @MainActor
    static func dismissAnyOpenMenu(in app: XCUIApplication, levels: Int = 3) {
        for _ in 0..<levels {
            guard app.menus.count > 0 else { return }
            app.typeKey(.escape, modifierFlags: [])
            _ = waitUntil(timeout: 1) { app.menus.count == 0 }
        }
    }

    /// Opens a submenu, picks `item` out of it, and returns once `outcome` is on screen.
    ///
    /// The one interaction in this suite that has flaked in two different tests, and the reason it
    /// is a helper rather than eight lines written twice.
    ///
    /// **What goes wrong.** Driving a nested AppKit menu means clicking a submenu parent, waiting for
    /// a child that exists before it is placed, and clicking that. Two frames have to be right and
    /// both are computed from a snapshot taken a moment earlier. When one is not, the menu closes
    /// having done nothing — and the only evidence is the *absence* of whatever the item was supposed
    /// to produce, which is indistinguishable from the app failing to produce it.
    ///
    /// `RequestLogUITests.testAddingRequestsToAnExistingJourneyFromTheLog` failed exactly that way on
    /// run #91 with a five-second wait for the sheet, and the fix applied then was to widen the wait
    /// to fifteen. **Run #98 failed at the same line, twice in the same run, at fifteen.** A sheet
    /// that is merely slow arrives inside fifteen seconds; one that never arrives is a different
    /// failure, and widening the clock was the wrong reading of the first one. That is what this
    /// replaces.
    ///
    /// **What it does.** Waits for each menu level to stop moving before clicking it, and if the
    /// outcome still does not arrive, dismisses whatever is left open and drives the whole
    /// interaction again — up to `attempts` times. Only the last attempt gets the full
    /// `outcomeTimeout`; the earlier ones get a short one, so a genuinely slow outcome is still
    /// waited out properly while a missed click is discovered quickly instead of costing the caller
    /// three long waits.
    ///
    /// **What it does not do, and this is the part worth being honest about.** A retry cannot tell a
    /// missed click apart from an app that intermittently fails to present. If the product is the
    /// flaky half, this hides it up to `attempts` times — so each re-open is recorded as an activity
    /// in the result bundle, and a caller that cares can compare. What it cannot do is turn a broken
    /// app green: every attempt ends in the same wait for the same `outcome`, so a sheet that never
    /// comes still fails, with the caller's own message.
    ///
    /// Returns whether `outcome` ever appeared, so the caller asserts with its own wording.
    @MainActor
    @discardableResult
    static func chooseFromSubmenu(
        in app: XCUIApplication,
        parent: XCUIElement,
        item: XCUIElement,
        thenAwait outcome: XCUIElement,
        // `@MainActor` on the closure type, not decoration: callers build it out of their own
        // `@MainActor` row helpers, and a plain `() -> Void` cannot call one synchronously under
        // Swift 6 isolation checking.
        reopenMenu: @MainActor () -> Void,
        menuIsAlreadyOpen: Bool = false,
        attempts: Int = 3,
        menuTimeout: TimeInterval = 5,
        outcomeTimeout: TimeInterval = 15
    ) -> Bool {
        let rounds = max(1, attempts)
        for attempt in 1...rounds {
            // An outcome that was only slower than the short wait has arrived by now. Driving the
            // menu again would pick the item a second time, or find no menu behind the sheet it
            // opened and report a failure with the sheet on screen; `click(_:expecting:)` checks the
            // same way.
            if attempt > 1, outcome.exists { return true }
            if attempt > 1 || !menuIsAlreadyOpen {
                if attempt > 1 {
                    // A marker with an empty body, and the only trace a retry leaves. It lands in the
                    // result bundle, which is uploaded on a red run — so "this passed, but only on
                    // the second open" is answerable rather than invisible. `print()` would not do:
                    // runner output never reaches the xcodebuild log this workflow reads.
                    XCTContext.runActivity(
                        named: "Re-opened the submenu (attempt \(attempt) of \(rounds))"
                    ) { _ in }
                }
                dismissAnyOpenMenu(in: app)
                reopenMenu()
            }

            guard parent.waitToExist(timeout: menuTimeout) else { continue }
            waitForStableFrame(parent)
            parent.click()

            guard item.waitToExist(timeout: menuTimeout) else { continue }
            waitForStableFrame(item)
            item.click()

            // The full clock only on the way out. An intermediate attempt that waits fifteen seconds
            // for something a missed click means will never come turns a three-attempt helper into a
            // forty-five-second one, on a test that already runs past a minute.
            let isLastAttempt = attempt == rounds
            let wait = isLastAttempt ? outcomeTimeout : min(outcomeTimeout, 4)
            if outcome.waitToExist(timeout: wait) { return true }
        }
        return outcome.exists
    }

    /// Picks an item from the pop-up `menu` by typing `typeSelection` and Return, and returns once
    /// `isChosen` holds.
    ///
    /// The one-level sibling of ``chooseFromSubmenu(in:parent:item:thenAwait:reopenMenu:menuIsAlreadyOpen:attempts:menuTimeout:outcomeTimeout:)``,
    /// but it never clicks the item, for two reasons seen on real runs.
    ///
    /// **Clicking can land on the wrong row.** On CI (macOS 26) three hover-and-click rounds on
    /// "404 Not Found" left the sheet on "409 Conflict", the row below. The likely cause is a pop-up
    /// that opens positioned over its current choice, so an item's frame can be stale by the time
    /// the click is synthesized.
    /// **On macOS 27 the items are not published at all**, so there is nothing to click. Typing the
    /// start of the title is AppKit's menu type-select, what a keyboard user does, and needs neither.
    /// `item` is only used to tell whether the menu is still open.
    ///
    /// **Escape is not free.** Once the menu has closed, the next Escape closes the sheet the menu
    /// sits in, so a retry presses it only while `item` shows the menu is open, and never in a
    /// loop. The outcome is a condition because a pop-up shows its choice in its value or title.
    /// Every retry is recorded in the result bundle, and a menu that never applies the choice
    /// still fails.
    @MainActor
    @discardableResult
    static func chooseFromPopUp(
        in app: XCUIApplication,
        menu: XCUIElement,
        item: XCUIElement,
        typeSelection: String,
        attempts: Int = 3,
        menuTimeout: TimeInterval = 5,
        itemTimeout: TimeInterval = 2,
        outcomeTimeout: TimeInterval = 5,
        until isChosen: () -> Bool
    ) -> Bool {
        let rounds = max(1, attempts)
        for attempt in 1...rounds {
            if attempt > 1 {
                XCTContext.runActivity(
                    named: "Re-opened the pop-up menu (attempt \(attempt) of \(rounds))"
                ) { _ in }
                if item.exists {
                    app.typeKey(.escape, modifierFlags: [])
                    _ = item.waitToDisappear(timeout: 1)
                }
            }

            guard menu.waitToExist(timeout: menuTimeout) else { continue }
            waitForStableFrame(menu)
            menu.click()

            // Where items are published, their appearance says the menu is open. Where they are
            // not, the wait simply runs out and the typing goes to the open menu all the same.
            _ = item.waitToExist(timeout: itemTimeout)
            app.typeText(typeSelection)
            app.typeKey(.return, modifierFlags: [])

            let wait = attempt == rounds ? outcomeTimeout : min(outcomeTimeout, 3)
            if waitUntil(timeout: wait, isChosen) { return true }
        }
        return false
    }

    /// Opens the pop-up or menu button `picker`, picks `option` from it, and returns once `isChosen`
    /// holds: the picker's own value, read back.
    ///
    /// For a control that holds a value, such as a method, a scope or a behaviour, where that value is
    /// the proof. ``chooseFromSubmenu(in:parent:item:thenAwait:reopenMenu:menuIsAlreadyOpen:attempts:menuTimeout:outcomeTimeout:)``
    /// is for an item that opens something, and
    /// ``chooseFromPopUp(in:menu:item:typeSelection:attempts:menuTimeout:itemTimeout:outcomeTimeout:until:)``
    /// for a pop-up whose items should only ever be typed.
    ///
    /// **Not `item.click()`.** XCUITest looks a menu item up twice, once to hover it and once to
    /// click it, and the open menu can be laid out again between the two. CI run 37147249690 hovered
    /// "404" at y 420 and clicked y 396, the menu's first row, "Use endpoints", which was the value
    /// the picker already had, so nothing changed and the test failed on an unchanged picker. A click
    /// here reads the item's frame until two readings agree, then clicks that point once as an offset
    /// from the main window, which does not move while a menu is open, so nothing is looked up again
    /// between reading the point and clicking it.
    ///
    /// **The value decides.** An attempt counts only when `isChosen` holds afterwards, whatever was
    /// clicked; a click that landed on the wrong row is retried. The last attempt uses the keyboard:
    /// AppKit's menu type-select, the first word of the title (or `typeSelection`) and Return, which
    /// needs no frames at all. The keyboard also stands in on any attempt whose open menu publishes no
    /// items to click, as macOS 27 does for some pop-ups.
    ///
    /// **What typing costs.** If the menu did not open, the letters and the Return go to the window,
    /// into a focused field or to a default button. `isChosen` then does not hold and the caller's
    /// assertion fails, so a closed menu can mislead the failure message but never pass the test.
    ///
    /// Each attempt is a named activity holding a note of what it did, the point it clicked or the
    /// keys it typed, so a choice that needed a second attempt is visible in the result bundle.
    /// `menuIsAlreadyOpen` skips the first click on `picker`, for a caller that opened the menu to
    /// assert something about its items first.
    ///
    /// Returns whether `isChosen` ever held, so the caller asserts with its own message.
    @MainActor
    @discardableResult
    static func chooseMenuOption(
        _ option: String,
        in picker: XCUIElement,
        of app: XCUIApplication,
        typeSelection: String? = nil,
        menuIsAlreadyOpen: Bool = false,
        attempts: Int = 3,
        itemTimeout: TimeInterval = 2,
        outcomeTimeout: TimeInterval = 5,
        until isChosen: () -> Bool
    ) -> Bool {
        let rounds = max(1, attempts)
        let typed = typeSelection ?? typeSelectPrefix(of: option)
        for attempt in 1...rounds {
            let isLastAttempt = attempt == rounds
            let chosen = XCTContext.runActivity(
                named: "Choose \"\(option)\" in \(describe(picker)) (attempt \(attempt) of \(rounds))"
            ) { _ -> Bool in
                if attempt > 1 || !menuIsAlreadyOpen {
                    if attempt > 1 { closeMenu(offering: option, of: picker, in: app) }
                    guard picker.waitToExist(timeout: 5) else { return false }
                    waitForStableFrame(picker)
                    picker.click()
                }

                var item: XCUIElement?
                _ = waitUntil(timeout: itemTimeout, pollInterval: 0.1) {
                    item = openMenuItem(titled: option, in: picker, of: app)
                    return item != nil
                }
                if !isLastAttempt, let item, let frame = waitForStableFrame(item) {
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    XCTContext.runActivity(named: "Clicked the item at \(point), read from \(frame)") { _ in }
                    windowAnchoredCoordinate(of: point, in: app).click()
                } else {
                    XCTContext.runActivity(named: "Typed \"\(typed)\" and Return into the open menu") { _ in }
                    app.typeText(typed)
                    app.typeKey(.return, modifierFlags: [])
                }
                return waitUntil(timeout: isLastAttempt ? outcomeTimeout : 3, pollInterval: 0.1, isChosen)
            }
            if chosen { return true }
        }
        return false
    }

    /// A menu item matched the way AppKit actually names one: by **title**.
    ///
    /// `label` is not it. CI printed the element `JourneyEditorUITests` kept catching,
    /// `MenuItem, {{6.0, 224.0}, {251.0, 24.0}}, identifier: '_restartNowRequested:', title:
    /// 'Restart'`, and an XCUITest element description prints `label:` when there is one. There was
    /// none. So `matching(NSPredicate(format: "label == %@", …))` matches *no* menu item in this
    /// app, while `app.menuItems["POST"]`, a subscript, which matches identifier *or* title, has
    /// always worked. All three attributes are asked for so neither spelling decides.
    private static func menuItemTitled(_ option: String) -> NSPredicate {
        NSPredicate(format: "identifier == %@ OR title == %@ OR label == %@", option, option, option)
    }

    /// One option of an open pop-up menu: the *picker's* option, never the menu bar's.
    ///
    /// **An open pop-up's menu lives app-wide, beside the menu bar's, not under the pop-up button.**
    /// The branch scoped to `picker` is kept only because a match there cannot possibly be a menu-bar
    /// item, and it costs one query when it misses.
    ///
    /// Which makes telling the two apart the whole job, because the menu bar's items are in the tree
    /// whether or not their menu is open. "Restart" is the journey editor's on-completion option and
    /// also the title of the Apple menu's `_restartNowRequested:` item. **Hittability is what
    /// separates them**, on evidence in both directions: that Apple item failed a click with "Not
    /// hittable" while its menu was closed, and an open pop-up's own items are clicked on every run.
    /// A non-hittable namesake is therefore never returned; clicking the Apple menu's Restart is not
    /// a failure a run recovers from.
    @MainActor
    static func openMenuItem(titled option: String, in picker: XCUIElement, of app: XCUIApplication) -> XCUIElement? {
        let scoped = picker.descendants(matching: .menuItem).matching(menuItemTitled(option)).firstMatch
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
    /// query. Only the hittable ones are described, because those are the open menu's, the same
    /// discriminator ``openMenuItem(titled:in:of:)`` selects on, so a failure shows exactly the set
    /// that was searched.
    @MainActor
    static func describeOpenMenus(in app: XCUIApplication) -> String {
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
    /// prefix, and a **space activates whatever is highlighted**, so typing "Strict sequence" whole
    /// would commit on the space and type "sequence" into whatever is behind the menu. A caller whose
    /// options share a first word passes its own `typeSelection`.
    static func typeSelectPrefix(of option: String) -> String {
        guard let firstWord = option.split(separator: " ").first else { return option }
        return String(firstWord)
    }

    /// Closes the picker's menu if an earlier attempt left it open, a click that hit no row.
    ///
    /// Only while `option` shows the menu is open: once it has closed, Escape goes to the window and
    /// closes the sheet the picker sits in (the hazard ``chooseFromPopUp(in:menu:item:typeSelection:attempts:menuTimeout:itemTimeout:outcomeTimeout:until:)``
    /// records).
    @MainActor
    private static func closeMenu(offering option: String, of picker: XCUIElement, in app: XCUIApplication) {
        guard openMenuItem(titled: option, in: picker, of: app) != nil else { return }
        app.typeKey(.escape, modifierFlags: [])
        _ = waitUntil(timeout: 2, pollInterval: 0.1) { openMenuItem(titled: option, in: picker, of: app) == nil }
    }

    /// A screen point as an offset from the app's main window. Clicking it resolves the window, which
    /// does not move while a menu is open, instead of looking up again the item the point was read
    /// from.
    @MainActor
    private static func windowAnchoredCoordinate(of point: CGPoint, in app: XCUIApplication) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - origin.x, dy: point.y - origin.y))
    }

    /// Activation is scoped to the process created by this launch. Other builds can share the
    /// bundle identifier, including the developer's normal session.
    static func activateLaunchedApp(processIdentifier: pid_t) {
        guard let runningApp = NSRunningApplication(processIdentifier: processIdentifier),
              !runningApp.isTerminated else { return }
        runningApp.unhide()
        runningApp.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
    }

    /// Ask this process to reopen its window without launching another copy through Launch Services.
    static func reopenLaunchedApp(processIdentifier: pid_t) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: .noReply, timeout: 2)
    }

    /// How long each activation attempt watches for `isReady`. Five attempts of three seconds keep
    /// the fifteen or so seconds the loop allowed when every probe blocked for a second of its own,
    /// while an app that is ready is noticed within a tenth of a second.
    static let readinessWindow: TimeInterval = 3

    /// Launches `app` and drives it to the foreground until `isReady` holds.
    ///
    /// Also exports the control-plane discovery override first — the environment binds at process
    /// spawn, so it must be in place before `launch()`, and it lives here so no suite can launch an
    /// app that writes the shared `control.json`. See ``controlFileOverridePath``. CI's screen,
    /// locale, clock, scroll bars and appearance (``UITestEnvironment``) go in here for the same
    /// reason, and so does the lock that keeps a second run on this Mac from starting
    /// (``UITestRunLock``).
    ///
    /// `isReady` should look once and return, as `assertVisible(timeout: 0)` does: it is polled.
    /// One that waits for itself still works, but each poll then lasts as long as its own timeout.
    ///
    /// Returns whether the app became usable, so the caller can assert with its own message.
    @MainActor
    @discardableResult
    static func launchAndBringToForeground(
        _ app: XCUIApplication,
        attempts: Int = 5,
        isReady: () -> Bool
    ) -> Bool {
        // Before anything launches: a second run's launch would end the first run's app and its
        // reset would delete the first run's store.
        guard UITestRunLock.acquire() else { return false }
        isolateControlPlaneDiscovery(for: app)
        UITestEnvironment.apply(to: app)
        let existingProcesses = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier))
        app.launch()
        var launchedProcess: pid_t?
        guard waitUntil(timeout: 5, {
            launchedProcess = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first { !existingProcesses.contains($0.processIdentifier) }?.processIdentifier
            return launchedProcess != nil
        }), let launchedProcess else {
            recordLaunchFailure("No new \(bundleIdentifier) process appeared within 5 s of launching", app: app)
            return false
        }
        activateLaunchedApp(processIdentifier: launchedProcess)
        guard app.wait(for: .runningForeground, timeout: 15) else {
            recordLaunchFailure("The app did not reach the foreground within 15 s", app: app)
            return false
        }

        for attempt in 0..<attempts {
            if isReady() { return true }

            app.activate()
            activateLaunchedApp(processIdentifier: launchedProcess)
            // From the first attempt. In all 162 launches in CI's logs the window became usable
            // right after this event, which the loop used to hold back until the second attempt, so
            // every test paid for a first attempt that never succeeded.
            reopenLaunchedApp(processIdentifier: launchedProcess)

            // Returns the moment the app is ready rather than always paying the full window.
            if waitUntil(timeout: readinessWindow, pollInterval: 0.1, isReady) { return true }
            XCTContext.runActivity(
                named: "Launch not ready after activation attempt \(attempt + 1) of \(attempts)"
            ) { _ in }
        }
        if isReady() { return true }
        recordLaunchFailure("The app never became ready in \(attempts) activation attempts", app: app)
        return false
    }

    /// Leaves `reason` and a picture of the whole screen in the result bundle when a launch fails.
    /// Whether a window appeared at all, or something was in front of it, is the first question a
    /// failed launch raises, and the caller's message cannot answer it.
    @MainActor
    private static func recordLaunchFailure(_ reason: String, app: XCUIApplication) {
        let state = switch app.state {
        case .runningForeground: "running in the foreground"
        // No `.runningBackgroundSuspended`: XCUIAutomation declares it only off macOS.
        case .runningBackground: "running in the background"
        case .notRunning: "not running"
        default: "in an unknown state"
        }
        XCTContext.runActivity(named: "\(reason); the app is \(state)") { activity in
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Screen when the launch failed"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
    }
}

/// Restores the user's clipboard after a UI test pastes fixture text or checks Copy URL.
/// Preserve each pasteboard flavor, including images and rich text, rather than only its string.
@MainActor
struct UITestClipboardSnapshot {
    private let items: [NSPasteboardItem]

    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
