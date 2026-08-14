import AppFeatures
import AppKit
import SwiftUI

@main
struct MimicApp: App {
    /// AppKit's half of the quit contract. SwiftUI has no hook that can *delay* termination, and
    /// delaying it is the whole point — see `MimicAppDelegate`.
    @NSApplicationDelegateAdaptor(MimicAppDelegate.self) private var appDelegate

    var body: some Scene {
        MimicScene()
    }
}

/// Answers ⌘Q with `.terminateLater` so the store can be drained before the process goes.
///
/// The saving lives in `ControlPlaneCoordinator` with the rest of the shutdown machinery; this
/// class is only the AppKit doorway to it. What the doorway buys is the runloop: `.terminateLater`
/// keeps the app alive — main actor serviced, event loop running — until the coordinator's drain
/// calls back, and only then is AppKit told to finish terminating. The hook this replaces,
/// `willTerminate`, fires after termination is already committed, where the only way to wait is to
/// park the main thread — and the write chain is main-actor work, so a quit from there could save
/// the open project but structurally could not drain the chain first, which is how a quit behind an
/// acknowledged `mimic project delete` could resurrect the deleted row. That observer still exists,
/// as the backstop for a termination that never came through here.
final class MimicAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ControlPlaneCoordinator.shared.handleTerminationRequest {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
