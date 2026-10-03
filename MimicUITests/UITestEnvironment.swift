import AppKit
import Darwin
import Foundation
import XCTest

/// The machine every UI test runs on, whichever Mac that is: CI's.
///
/// CI's macOS runners have a 1024×768 display, an en_US locale on a 12-hour clock, light
/// appearance, and no trackpad, so AppKit draws the legacy scroll bars that are always visible. A
/// developer's Mac is usually larger, often on a 24-hour clock or dark, and with a trackpad its scroll
/// bars stay hidden until something scrolls. Each difference changed what a test met. A scroll bar
/// that only CI drew lay over "Add step", so the click landed on the scroller and the step sheet never
/// opened; a 24-hour clock gave the request log a narrower time column; a display wider than 1024pt
/// gave every window size the app takes from the screen a different value. Tests then failed on CI
/// and passed locally, and nothing short of a CI run could reproduce them.
///
/// ``apply(to:)`` gives every launch CI's values, from `UITestApp.launchAndBringToForeground`, the
/// one path every suite launches through. A suite that sets one of these values itself keeps its
/// own: the appearance tests choose dark or light, and nothing here overrides them.
///
/// What this cannot pin: menus, pop-ups and sheets that AppKit places on the real screen, which near
/// its bottom edge can open differently on a taller display, and the section views that size a sheet
/// from the main screen's height themselves.
enum UITestEnvironment {

    /// CI's visible frame, in points: the 1024×768 display under a 31pt menu bar and above the Dock.
    /// Measured from every frame the layout audit recorded on CI (each window's accessibility frame
    /// starts at y 31 and fills 1024×677), not worked out from the display size.
    static let screen = CGSize(width: 1024, height: 677)

    /// The key `UITestSupport.pinnedScreenEnvironmentKey` reads, spelled here because this target
    /// links no app code, like ``UITestApp/controlFileEnvironmentKey``.
    static let screenEnvironmentKey = "MIMIC_UITEST_SCREEN"

    /// Every value is an argument-domain default (`-<key> <value>`), which outranks the Mac's own
    /// settings for that one process and changes nothing else on it:
    ///
    /// - `AppleLanguages` and `AppleLocale` are the language and region, the pair Xcode's scheme
    ///   options for App Language and App Region pass.
    /// - `AppleICUForce24HourTime` and `AppleICUForce12HourTime` are what the Mac's 24-hour time
    ///   setting writes, and the locale reads them; en_US alone is already 12-hour, so these only
    ///   undo a Mac that forces 24-hour time for every locale.
    /// - `AppleShowScrollBars` is System Settings' "Show scroll bars"; `Always` is the legacy style
    ///   AppKit picks itself on a Mac with no trackpad.
    /// - `AppleInterfaceStyle` with `NSRequiresAquaSystemAppearance` is light appearance, the same
    ///   pair the appearance tests already pass for it.
    @MainActor
    static func apply(to app: XCUIApplication) {
        if app.launchEnvironment[screenEnvironmentKey] == nil {
            app.launchEnvironment[screenEnvironmentKey] = "\(Int(screen.width))x\(Int(screen.height))"
        }
        setDefault("-AppleLanguages", to: "(en)", in: app)
        setDefault("-AppleLocale", to: "en_US", in: app)
        setDefault("-AppleICUForce24HourTime", to: "NO", in: app)
        setDefault("-AppleICUForce12HourTime", to: "YES", in: app)
        setDefault("-AppleShowScrollBars", to: "Always", in: app)
        // A suite that chose an appearance chose both keys, so it is judged by the first alone.
        if !app.launchArguments.contains("-AppleInterfaceStyle") {
            app.launchArguments += ["-AppleInterfaceStyle", "Light", "-NSRequiresAquaSystemAppearance", "YES"]
        }
    }

    /// Adds `key value` unless the launch already names `key`: a suite's own choice wins, and a
    /// relaunch of the same `XCUIApplication` does not collect a second copy.
    @MainActor
    private static func setDefault(_ key: String, to value: String, in app: XCUIApplication) {
        guard !app.launchArguments.contains(key) else { return }
        app.launchArguments += [key, value]
    }

    /// Fails the test when this Mac's display has less room than CI's.
    ///
    /// The app caps every size it takes from the screen at ``screen``, so a larger display behaves
    /// like CI's, but a smaller one cannot: its windows would lay out smaller than CI's, and every
    /// geometry assertion after this would fail with a message about something else. The same goes
    /// for a runner image that shrinks the visible frame, with a larger Dock or a taller menu bar.
    /// Either way the run fails here, once per test, in a line that names the cause.
    @MainActor
    static func failUnlessDisplayFitsPinnedScreen(file: StaticString = #filePath, line: UInt = #line) {
        // The display new windows open on, the one with the menu bar.
        guard let visible = NSScreen.screens.first?.visibleFrame,
              visible.width < screen.width || visible.height < screen.height
        else { return }
        XCTFail(
            "This display's visible frame is \(Int(visible.width))×\(Int(visible.height))pt, smaller than "
                + "the \(Int(screen.width))×\(Int(screen.height))pt UI tests pin to (CI's). Layouts would "
                + "differ from CI's; use a larger display, or update UITestEnvironment.screen if CI's has changed.",
            file: file,
            line: line
        )
    }
}

/// One UI test run per Mac at a time.
///
/// Two runs on one Mac share far more than its screen: the store (`mimic-uitests.sqlite`), the
/// defaults suite, the fixed ports several suites bind, and the one GUI session every click and key
/// goes to. A second run's reset deleted the first run's store under it, and the first run then hung
/// or asserted against a state no click could produce, which reads as a flaky test rather than as two
/// runs fighting. With this, the second run fails at its first launch and says why.
///
/// An advisory `flock` on a file in the runner's temporary directory, which every checkout's runner
/// on the Mac shares. It does not queue behind the other run. The kernel releases the lock when the
/// runner process exits, however it exits, so a crashed or killed run cannot leave the Mac locked.
/// xcodebuild restarts a runner that crashed or ran out of time, and the new one can start while
/// the old one is still exiting, so a process's first attempt retries for ``grace``; a run refused
/// once then tries once per test, so it fails each of them at once rather than waiting again.
/// Anything that stops the lock being taken at all, such as a file that cannot be opened, lets the
/// run go ahead unlocked, because the lock guards a local hazard and must never be what fails a
/// run. CI runs one runner on a fresh machine, so there it is always free.
enum UITestRunLock {

    static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-uitests.lock").path

    static let grace: TimeInterval = 10

    /// The open lock file, kept for the rest of the process so the lock is held until it exits.
    @MainActor private static var descriptor: Int32?
    @MainActor private static var hasTried = false

    /// Takes the lock, once per runner process, or fails the current test naming the run that holds
    /// it. Returns whether the test may go on.
    @MainActor
    static func acquire(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if descriptor != nil { return true }
        // Close-on-exec, so nothing this process starts can inherit the lock and outlive it.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }

        var failure: Int32 = 0
        let wait = hasTried ? 0 : grace
        hasTried = true
        _ = UITestApp.waitUntil(timeout: wait, pollInterval: 0.1) {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                failure = 0
                return true
            }
            failure = errno
            // Only another run holding the lock is worth waiting out.
            return failure != EWOULDBLOCK && failure != EINTR
        }
        guard failure == 0 else {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            close(fd)
            // Only another run holding the lock stops this one; any other failure is the lock's own.
            guard failure == EWOULDBLOCK || failure == EINTR else { return true }
            XCTFail(
                "Another Mimic UI test run is using this Mac (runner pid \(holder.isEmpty ? "unknown" : holder), "
                    + "lock \(path)). Two runs share one store, one defaults suite and one screen, and "
                    + "would corrupt each other. Let it finish or stop it, then run again.",
                file: file,
                line: line
            )
            return false
        }

        // The holder's pid, for the message a second run prints.
        if ftruncate(fd, 0) == 0 {
            let pid = Array("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        descriptor = fd
        return true
    }
}
