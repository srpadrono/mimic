import AppKit
import DesignSystem
import Domain
import EndpointsFeature
import JourneysFeature
import MimicFixtures
import ServerFeature
import SwiftUI
import WorkspaceShell

/// The Components board's cards whose views belong to a section rather than to the design system:
/// they take `Domain` values, so they are built here from the real rows, in the board's card.
@MainActor
extension GalleryCatalog {
    static let componentsFromSections: [GalleryEntry] = [
        GalleryEntry("ds.toolbar", "Toolbar controls", group: .components, size: CGSize(width: 432, height: 239)) {
            DSCatalogCard("Toolbar",
                          detail: "Glass over the title bar. Run and Stop share one round button; the actions share a capsule.") {
                HStack(spacing: 10) {
                    GalleryComponentCards.runButton(.stopped)
                    GalleryComponentCards.runButton(.running(port: DesignFixtures.port))
                    GalleryToolbarGroup {
                        WorkspaceImportMenu(inToolbar: true, actions: .none)
                        WorkspaceServerSettingsButton(restartRequired: false, action: {})
                            .labelStyle(.iconOnly)
                    }
                    GalleryToolbarGroup {
                        WorkspaceOverflowMenu(state: GalleryToolbarFixture.compact.state, actions: .none) {
                            GalleryToolbarFixture.compact.runMenuItem
                        }
                    }
                }
            }
        },
        GalleryEntry("ds.serverStatus", "Server status", group: .components, size: CGSize(width: 432, height: 239)) {
            DSCatalogCard("Server status", detail: "The address over the server\u{2019}s state. Opens the status popover.") {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    GalleryComponentCards.well(.stopped, requests: 0, unmatched: 0)
                    GalleryComponentCards.well(.starting, requests: 0, unmatched: 0)
                    GalleryComponentCards.well(.running(port: DesignFixtures.port), requests: 142, unmatched: 3,
                                               bound: GalleryToolbarFixture.twoPorts)
                    GalleryComponentCards.well(.error("Address already in use"), requests: 0, unmatched: 0,
                                               conflictingPort: DesignFixtures.port)
                }
            }
        },
        GalleryEntry("ds.sidebarRow", "Sidebar row", group: .components, size: CGSize(width: 432, height: 368)) {
            DSCatalogCard("Sidebar row", detail: "28 pt, rounded inset selection, grey when the sidebar is not focused.") {
                DSNavigatorGroup(name: "Catalog", count: 4, itemName: "endpoints", isCollapsed: false,
                                 identifier: "gallery.sidebarRow.group", disclosure: .onHover) {}
                    .padding(.horizontal, DSSpacing.sm)
                VStack(spacing: DSNavigatorMetrics.rowGap) {
                    GalleryComponentCards.sidebarRow(DesignFixtures.endpoints[1], caption: "Default")
                    GalleryComponentCards.sidebarRow(DesignFixtures.endpoints[3], fill: DSColors.hover, caption: "Hover")
                    GalleryComponentCards.sidebarRow(GalleryComponentCards.productsServing503, isSelected: true,
                                                     fill: DSColors.selection, isFocused: true)
                    GalleryComponentCards.sidebarRow(GalleryComponentCards.productsServing503, isSelected: true,
                                                     fill: DSColors.selectionInactive)
                }
                Text("The code on the right shows a live response that isn\u{2019}t a success.")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
                    .padding(.top, -6)
            }
        },
        GalleryEntry("ds.scenarioRow", "Scenario row", group: .components, size: CGSize(width: 432, height: 235)) {
            DSCatalogCard("Scenario row",
                          detail: "The radio marks what the server serves. The highlight marks what you\u{2019}re editing.") {
                VStack(spacing: DSSpacing.xxs) {
                    let scenarios = DesignFixtures.products.scenarios
                    ScenarioRow(scenario: scenarios[0], isActive: true, isOnlyScenario: false,
                                onTap: {}, onDuplicate: {}, onDelete: {})
                    ScenarioRow(scenario: scenarios[1], isActive: false, isEdited: true, isOnlyScenario: false,
                                onTap: {}, onDuplicate: {}, onDelete: {})
                    ScenarioRow(scenario: scenarios[2], isActive: false, isOnlyScenario: false,
                                onTap: {}, onDuplicate: {}, onDelete: {})
                }
            }
        },
        // The real rows at the card's width, with a run in flight: served, current, not reached.
        // Facts give way to the run readout as the row narrows, so the card is redrawn to match.
        GalleryEntry("ds.journeyStep", "Journey step row", group: .components, size: CGSize(width: 432, height: 235)) {
            DSCatalogCard("Journey step", detail: "Numbered nodes show progress. The current step is ringed.") {
                VStack(spacing: DSSpacing.xxs) {
                    let steps = DesignFixtures.paymentRetry.steps
                    let progress = DesignFixtures.paymentRetryStatus.steps
                    JourneyStepRow(step: steps[0], index: 0, progress: progress[0])
                    JourneyStepRow(step: steps[2], index: 1, progress: progress[2])
                    JourneyStepRow(step: steps[4], index: 2, progress: progress[4])
                }
                // The card's rows run 14pt past its padding, 4pt from its edge.
                .padding(.horizontal, -14)
            }
        },
    ]
}

/// The pieces the section-built Components cards share.
@MainActor
enum GalleryComponentCards {
    /// The round glass Run or Stop button, as the toolbar strip draws it.
    static func runButton(_ state: ServerState) -> some View {
        ServerToggleButton(serverState: state, onStart: {}, onStop: {})
            .buttonStyle(.borderless)
            .frame(width: GalleryToolbarStrip.itemHeight, height: GalleryToolbarStrip.itemHeight)
            .galleryGlass(in: Circle())
    }

    /// The toolbar's server well for the two-port project, in one state.
    static func well(
        _ state: ServerState, requests: Int, unmatched: Int,
        bound: ServerConfiguration? = nil, conflictingPort: Int? = nil
    ) -> some View {
        ServerStatusWell(
            serverState: state,
            projectName: DesignFixtures.projectName,
            requestCount: requests,
            unmatchedCount: unmatched,
            configuration: GalleryToolbarFixture.twoPorts,
            boundConfiguration: bound,
            conflictingPort: conflictingPort
        )
    }

    /// `/products` while it serves Out of stock, so the row shows its 503.
    static var productsServing503: Endpoint {
        var endpoint = DesignFixtures.products
        endpoint.activeScenarioID = endpoint.scenarios[1].id
        return endpoint
    }

    /// A navigator row with the chrome a `List` would give it drawn by hand: native selection never
    /// draws offscreen. `caption` is the board's state note, laid over the row in tertiary ink.
    static func sidebarRow(
        _ endpoint: Endpoint, isSelected: Bool = false, fill: Color = .clear,
        isFocused: Bool = false, caption: String? = nil
    ) -> some View {
        EndpointSidebarRow(endpoint: endpoint, isSelected: isSelected)
            .padding(.horizontal, DSSpacing.sm)
            .frame(height: DSNavigatorMetrics.rowHeight)
            .overlay(alignment: .trailing) {
                if let caption {
                    Text(caption)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelTertiary)
                        .padding(.trailing, DSSpacing.sm)
                }
            }
            // The route has no colour of its own; a focused List turns it white on the selection.
            .foregroundStyle(isFocused ? Color.white : DSColors.labelPrimary)
            .background(RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous).fill(fill))
            .environment(\.backgroundProminence, isFocused ? .increased : .standard)
    }
}

/// The design canvas's `--desk`, behind the Alerts board's popover and autosave states.
enum GalleryDesk {
    static let color = galleryDynamicColor(light: NSColor(srgbRed: 0xE4 / 255, green: 0xE6 / 255, blue: 0xEA / 255, alpha: 1),
                                           dark: NSColor(srgbRed: 0x17 / 255, green: 0x19 / 255, blue: 0x1D / 255, alpha: 1))
}

/// A popover's box as the Alerts board draws it (`.pop`): NSPopover's material, arrow and shadow
/// never draw offscreen, so the content is checked on a painted stand-in over the desk.
struct GalleryPopover<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private static var fill: Color {
        galleryDynamicColor(light: NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 0.98),
                            dark: NSColor(srgbRed: 50 / 255, green: 50 / 255, blue: 54 / 255, alpha: 0.97))
    }

    private static var ring: Color {
        galleryDynamicColor(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.12))
    }

    var body: some View {
        ZStack(alignment: .top) {
            GalleryDesk.color
            content
                .frame(width: DSLayout.popoverWidth)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Self.fill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.ring, lineWidth: 0.5))
        }
    }
}

/// A colour that follows the rendered appearance, as the canvas's light and dark themes do.
func galleryDynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}
