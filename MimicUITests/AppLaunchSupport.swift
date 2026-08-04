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
    /// Returns whether the app became usable, so the caller can assert with its own message.
    @MainActor
    @discardableResult
    static func launchAndBringToForeground(
        _ app: XCUIApplication,
        attempts: Int = 5,
        isReady: () -> Bool
    ) -> Bool {
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
