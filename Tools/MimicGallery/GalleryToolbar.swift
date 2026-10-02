import AppKit
import DesignSystem
import Domain
import Foundation
import MimicFixtures
import ServerFeature
import SwiftUI
import WorkspaceShell

/// One state of the workspace toolbar, from the design fixtures: the values `WorkspaceToolbar`
/// lays out, and the server section's Run button and address well that fill its slots.
struct GalleryToolbarFixture {
    var serverState: ServerState
    var layout: WorkspaceToolbarLayout
    var projectName: String? = DesignFixtures.projectName
    var configuration: ServerConfiguration? = GalleryToolbarFixture.twoPorts
    /// What the running server is bound to; differs from `configuration` when ports changed.
    var boundConfiguration: ServerConfiguration?
    var requestCount = 142
    var unmatchedCount = 3
    var isInspectorPresented = true

    /// The approved toolbar design's project: Storefront on 18086 and Accounts on 18087.
    static var twoPorts: ServerConfiguration {
        var configuration = DesignFixtures.serverConfiguration
        configuration.backends = [
            BackendConfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000087")!,
                                 name: "Accounts", port: 18_087),
        ]
        return configuration
    }

    static let running = GalleryToolbarFixture(serverState: .running(port: DesignFixtures.port), layout: .expanded,
                                               boundConfiguration: twoPorts)
    static let stopped = GalleryToolbarFixture(serverState: .stopped, layout: .expanded,
                                               requestCount: 0, unmatchedCount: 0)
    /// Both ports moved while the server ran, so it serves 18086 and 18087 until a restart.
    static let restartRequired: GalleryToolbarFixture = {
        var configured = twoPorts
        configured.port = 18_090
        configured.backends[0].port = 18_091
        return GalleryToolbarFixture(serverState: .running(port: DesignFixtures.port), layout: .expanded,
                                     configuration: configured, boundConfiguration: twoPorts)
    }()
    /// The design's compact centre column, 480pt wide: the tier the window uses at that width.
    static let compact = GalleryToolbarFixture(serverState: .running(port: DesignFixtures.port), layout: .compactSummary,
                                               boundConfiguration: twoPorts)
    /// No project open: the window skeleton's toolbar.
    static let empty = GalleryToolbarFixture(serverState: .stopped, layout: .expanded, projectName: nil,
                                             configuration: nil, requestCount: 0, unmatchedCount: 0,
                                             isInspectorPresented: false)

    var state: WorkspaceToolbarState {
        WorkspaceToolbarState(
            layout: layout,
            projectName: projectName,
            // The toolbar board's summary of Acme Storefront, which the welcome board repeats. The
            // fixtures list only the rows the other boards draw, so their counts are not the summary.
            projectContents: WorkspaceProjectIdentity.contents(
                endpoints: projectName == nil ? 0 : 12,
                journeys: projectName == nil ? 0 : 3
            ),
            restartRequired: serverState.runningPort != nil && boundConfiguration.map { bound in
                configuration.map { !$0.hasSameListeners(as: bound) } ?? false
            } == true,
            unmatchedCount: unmatchedCount,
            isRequestLogShown: true,
            isInspectorPresented: isInspectorPresented,
            canPresentInspector: projectName != nil
        )
    }

    var run: some View {
        ServerToggleButton(serverState: serverState, onStart: {}, onStop: {})
    }

    var runMenuItem: some View {
        ServerToggleMenuItem(serverState: serverState, onStart: {}, onStop: {})
    }

    var status: some View {
        ServerStatusWell(
            serverState: serverState,
            projectName: projectName,
            requestCount: requestCount,
            unmatchedCount: unmatchedCount,
            compact: layout.usesCompactSummary,
            showsListenerCount: !layout.usesCompactSummary,
            configuration: configuration,
            boundConfiguration: boundConfiguration,
            runningSince: DesignFixtures.now.addingTimeInterval(-14 * 60),
            onShowUnmatched: {},
            onShowSettings: {},
            onToggleServer: {}
        )
    }

    /// The real toolbar, for a window entry opened in its own window.
    var toolbar: some ToolbarContent {
        WorkspaceToolbar(state: state, actions: .none) { run } runMenuItem: { runMenuItem } status: { status }
    }
}

/// The toolbar's items laid out on the canvas, in the order and groups the window's toolbar gives
/// them. A toolbar draws only in a window's title bar, so the gallery canvas and the fidelity
/// report see this strip; "Open in a window" shows the real one.
struct GalleryToolbarStrip: View {
    let fixture: GalleryToolbarFixture

    private var state: WorkspaceToolbarState { fixture.state }

    var body: some View {
        // The window's toolbar spaces its items 8pt apart; the items bring any extra space themselves.
        HStack(spacing: DSSpacing.sm) {
            if !state.layout.foldsRun {
                fixture.run
                    .buttonStyle(.borderless)
                    .frame(width: Self.itemHeight, height: Self.itemHeight)
                    .galleryGlass(in: Circle())
            }
            // A toolbar item takes its content's own width; in an HStack the identity's maximum-width
            // frame would instead stretch to that maximum and push the server well right.
            WorkspaceProjectIdentity(state: state)
                .fixedSize(horizontal: true, vertical: false)
            WorkspaceToolbarStatus(state: state) { fixture.status }
            Spacer(minLength: 0)
            group {
                if state.layout.usesOverflow {
                    WorkspaceOverflowMenu(state: state, actions: .none) { fixture.runMenuItem }
                } else {
                    WorkspaceImportMenu(inToolbar: true, actions: .none)
                        .disabled(!state.hasProject)
                    WorkspaceServerSettingsButton(restartRequired: state.restartRequired, action: {})
                        .disabled(!state.hasProject)
                        .labelStyle(.iconOnly)
                }
            }
            if !state.layout.usesOverflow, !state.isInspectorPresented {
                group {
                    WorkspaceRequestLogToggle(isShown: state.isRequestLogShown, action: {})
                        .labelStyle(.iconOnly)
                    WorkspaceInspectorToggle(isPresented: state.isInspectorPresented,
                                             canPresent: state.canPresentInspector, action: {})
                        .labelStyle(.iconOnly)
                }
            }
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColors.window)
    }

    /// The round Run button and the glass groups beside it.
    static let itemHeight: CGFloat = 36

    /// Buttons that share one glass capsule, as a `ToolbarItemGroup` draws them.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GalleryToolbarGroup(content: content)
    }
}

/// Toolbar buttons that share one glass capsule, as a `ToolbarItemGroup` draws them. The strip and
/// the Components board's toolbar card draw the same capsule.
struct GalleryToolbarGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(minWidth: WorkspaceToolbarLayout.actionWidth, minHeight: GalleryToolbarStrip.itemHeight)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .padding(.horizontal, DSSpacing.xs)
        .galleryGlass(in: Capsule())
    }
}

extension View {
    /// The toolbar's glass as the design draws it: a translucent fill and a hairline. `glassEffect`
    /// draws only in a window, so the offscreen renders the fidelity report scores came out bare.
    /// The floating sidebar and inspector panels are the same glass, at the design's 14pt radius.
    func galleryGlass(in shape: some InsettableShape) -> some View {
        background(shape.fill(GalleryGlass.fill))
            .overlay(shape.strokeBorder(GalleryGlass.border, lineWidth: 0.5))
    }
}

/// The design canvas's `--glass` and `--glass-b`. The design system has no glass token: the real
/// toolbar's glass is the system's.
private enum GalleryGlass {
    static let fill = dynamic(light: NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 243 / 255, alpha: 0.94),
                              dark: NSColor(srgbRed: 46 / 255, green: 46 / 255, blue: 50 / 255, alpha: 0.9))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
