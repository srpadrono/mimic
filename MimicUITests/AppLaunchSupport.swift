import AppKit
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

    /// Exports the discovery-file override into `app`'s launch environment, unless the suite has
    /// already named one — an explicit path is the suite's to keep, the way an explicit
    /// `MIMIC_DATABASE_PATH` wins over the computed store.
    @MainActor
    static func isolateControlPlaneDiscovery(for app: XCUIApplication) {
        guard app.launchEnvironment[controlFileEnvironmentKey] == nil else { return }
        app.launchEnvironment[controlFileEnvironmentKey] = controlFileOverridePath
    }

    /// Waits for a condition, polling until it holds or the deadline passes.
    ///
    /// Preferred over a fixed pause, which is wrong in both directions: too short and the test is
    /// flaky, too long and every run pays for it. Polling returns the moment the condition is true
    /// and still fails within a bounded time when it never becomes true.
    @discardableResult
    static func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return condition()
    }

    /// Waits until any one of `elements` exists, polling all of them together.
    ///
    /// Prefer this over `a.waitForExistence(t) || b.waitForExistence(t)`. That form waits out `a`'s
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

    /// Waits until `element` reports the same non-empty frame twice in a row.
    ///
    /// `waitForExistence` answers "is it in the accessibility tree", which for an AppKit menu happens
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
    @MainActor
    static func waitForStableFrame(_ element: XCUIElement, timeout: TimeInterval = 2) {
        var previous: CGRect?
        _ = waitUntil(timeout: timeout, pollInterval: 0.1) {
            let current = (try? element.snapshot())?.frame
            defer { previous = current }
            guard let current, current.width > 0, current.height > 0 else { return false }
            return current == previous
        }
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

            guard parent.waitForExistence(timeout: menuTimeout) else { continue }
            waitForStableFrame(parent)
            parent.click()

            guard item.waitForExistence(timeout: menuTimeout) else { continue }
            waitForStableFrame(item)
            item.click()

            // The full clock only on the way out. An intermediate attempt that waits fifteen seconds
            // for something a missed click means will never come turns a three-attempt helper into a
            // forty-five-second one, on a test that already runs past a minute.
            let isLastAttempt = attempt == rounds
            let wait = isLastAttempt ? outcomeTimeout : min(outcomeTimeout, 4)
            if outcome.waitForExistence(timeout: wait) { return true }
        }
        return false
    }

    static var launchedApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }

    static func activateLaunchedApp() {
        // The app may still be starting; wait for it to exist rather than sleeping a guessed interval.
        guard waitUntil(timeout: 2, { launchedApps.isEmpty == false }) else { return }

        for runningApp in launchedApps {
            runningApp.unhide()
            runningApp.activate(
                from: NSRunningApplication.current,
                options: [.activateAllWindows]
            )
        }
    }

    static func reopenLaunchedApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)

        // Wait for the app to actually be frontmost rather than pausing and hoping. `openApplication`
        // signals when the request was accepted, not when the window is up.
        waitUntil(timeout: 2) {
            launchedApps.contains { $0.isActive }
        }
    }

    /// Launches `app` and drives it to the foreground until `isReady` holds.
    ///
    /// Also exports the control-plane discovery override first — the environment binds at process
    /// spawn, so it must be in place before `launch()`, and it lives here so no suite can launch an
    /// app that writes the shared `control.json`. See ``controlFileOverridePath``.
    ///
    /// Returns whether the app became usable, so the caller can assert with its own message.
    @MainActor
    @discardableResult
    static func launchAndBringToForeground(
        _ app: XCUIApplication,
        attempts: Int = 5,
        isReady: () -> Bool
    ) -> Bool {
        isolateControlPlaneDiscovery(for: app)
        app.launch()
        guard app.wait(for: .runningForeground, timeout: 15) else { return false }

        for attempt in 0..<attempts {
            if isReady() { return true }

            activateLaunchedApp()
            app.activate()
            if attempt > 0 {
                reopenLaunchedApp()
            }

            guard attempt < attempts - 1 else { break }
            // Give the window server a moment before the next attempt, but stop as soon as the app is
            // ready rather than always paying the full pause.
            waitUntil(timeout: 0.5) { isReady() }
        }
        return isReady()
    }
}
