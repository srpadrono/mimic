import AppKit
import Persistence
import SwiftUI

/// Gives the welcome screen and the workspace their own window sizes, although they share one window.
///
/// Without this the window kept whatever frame it last had. Close a project from a 1280×988 workspace,
/// or relaunch after quitting from one, and the welcome screen's fixed-size content sat in the top
/// half of a window built for three panels. Now the welcome screen takes its board's size, centred
/// where the window was, and opening a project gives the workspace back the frame it was left at.
struct WindowRoleFrame: NSViewRepresentable {
    enum Role: Equatable {
        case welcome
        case workspace
    }

    /// The workspace's first size, before it has been left at one: the window's size before the
    /// welcome screen had a size of its own.
    static let defaultWorkspaceSize = CGSize(width: 1090, height: 760)

    let role: Role
    let store: PanelLayoutStore
    var welcomeSize = CGSize(width: 880, height: 560)

    func makeNSView(context: Context) -> RoleView { RoleView() }

    func updateNSView(_ view: RoleView, context: Context) {
        view.store = store
        view.welcomeSize = welcomeSize
        view.apply(role)
    }

    /// A frame of `size` centred on `frame`, inside `visible`: the welcome screen's, or a first workspace's.
    /// Pure so the arithmetic is testable without a window.
    nonisolated static func centredFrame(around frame: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        var origin = CGPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    final class RoleView: NSView {
        var store: PanelLayoutStore?
        var welcomeSize = CGSize(width: 880, height: 560)
        private var appliedRole: Role?
        private var pendingRole: Role?
        /// The workspace's frame from this session, for when no store has one yet.
        private var workspaceFrame: CGRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let pendingRole { apply(pendingRole) }
        }

        func apply(_ role: Role) {
            guard let window, !window.styleMask.contains(.fullScreen) else {
                pendingRole = role
                return
            }
            guard role != appliedRole else { return }
            let previous = appliedRole
            appliedRole = role
            pendingRole = nil
            // Applied after SwiftUI has swapped the content, so its new minimum size is in place.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                switch role {
                case .welcome:
                    self.showWelcome(in: window, leavingWorkspace: previous == .workspace || previous == nil)
                case .workspace:
                    guard previous == .welcome else { return }
                    self.showWorkspace(in: window)
                }
            }
        }

        private func showWelcome(in window: NSWindow, leavingWorkspace: Bool) {
            let frame = window.frame
            // Only a frame larger than the welcome screen is a workspace's; a launch straight to the
            // welcome screen at its own size has nothing to remember.
            if leavingWorkspace, frame.width > welcomeSize.width || frame.height > welcomeSize.height {
                workspaceFrame = frame
                store?.saveWorkspaceFrame(frame)
            }
            guard let visible = window.screen?.visibleFrame else { return }
            let target = WindowRoleFrame.centredFrame(around: frame, size: welcomeSize, visible: visible)
            guard target != frame else { return }
            window.setFrame(target, display: true, animate: false)
        }

        private func showWorkspace(in window: NSWindow) {
            // With no frame of its own yet, the workspace opens at the size the window first had
            // before the welcome screen took its own: kept at the welcome screen's size, a first
            // project opened too narrow for the inspector, which then hid itself.
            guard let visible = window.screen?.visibleFrame else { return }
            var target = store?.loadWorkspaceFrame() ?? workspaceFrame
                ?? WindowRoleFrame.centredFrame(
                    around: window.frame, size: WindowRoleFrame.defaultWorkspaceSize, visible: visible
                )
            if let fitted = WindowScreenFit.fittedFrame(target, visible: visible, minimum: window.minSize) {
                target = fitted
            }
            guard target != window.frame else { return }
            window.setFrame(target, display: true, animate: false)
        }
    }
}
