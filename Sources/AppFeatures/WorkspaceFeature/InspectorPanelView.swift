import SwiftUI
import Domain
import DesignSystem

/// The right-hand column. It shows one thing at a time: an endpoint's scenarios, a journey, or the
/// project overview. A logged request opens beside the request log in the centre column instead, and
/// the inspector steps aside while it is open.
struct InspectorPanelView: View {
    let endpoint: Endpoint?
    let journey: JourneyInspector.Context?
    /// Whether the column is on screen. Its header lives in the inspector's own toolbar section,
    /// level with the window's toolbar, and must leave with the column.
    let showsHeader: Bool
    let overview: InspectorOverview.Summary?
    let onShowJourneys: () -> Void
    let onAddScenario: (_ endpointID: UUID, _ name: String) -> Void
    let onSetActiveScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicateScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDeleteScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onRenameScenario: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void
    let endpointTraffic: [RequestLog]
    let onSelectTrafficLog: (UUID) -> Void
    let endpointSettings: EndpointInspectorSettings.Context?

    @State private var addScenarioTarget: ScenarioTarget?

    struct ScenarioTarget: Identifiable {
        let id: UUID
    }

    public init(
        endpoint: Endpoint?,
        overview: InspectorOverview.Summary? = nil,
        journey: JourneyInspector.Context? = nil,
        showsHeader: Bool = true,
        endpointTraffic: [RequestLog] = [],
        endpointSettings: EndpointInspectorSettings.Context? = nil,
        onShowJourneys: @escaping () -> Void = {},
        onSelectTrafficLog: @escaping (UUID) -> Void = { _ in },
        onAddScenario: @escaping (_ endpointID: UUID, _ name: String) -> Void,
        onSetActiveScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDuplicateScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDeleteScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onRenameScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in }
    ) {
        self.endpoint = endpoint
        self.overview = overview
        self.journey = journey
        self.showsHeader = showsHeader
        self.endpointTraffic = endpointTraffic
        self.endpointSettings = endpointSettings
        self.onShowJourneys = onShowJourneys
        self.onSelectTrafficLog = onSelectTrafficLog
        self.onAddScenario = onAddScenario
        self.onSetActiveScenario = onSetActiveScenario
        self.onDuplicateScenario = onDuplicateScenario
        self.onDeleteScenario = onDeleteScenario
        self.onRenameScenario = onRenameScenario
    }

    enum Mode: Equatable {
        case scenarios
        case journey
        case overview
        case empty

        var title: String {
            switch self {
            case .scenarios: "Scenarios"
            case .journey: "Journey"
            case .overview: "Overview"
            case .empty: "Inspector"
            }
        }
    }

    static func mode(
        hasEndpoint: Bool,
        hasOverview: Bool,
        hasJourney: Bool = false
    ) -> Mode {
        if hasEndpoint { return .scenarios }
        if hasJourney { return .journey }
        if hasOverview { return .overview }
        return .empty
    }

    var mode: Mode {
        Self.mode(
            hasEndpoint: endpoint != nil,
            hasOverview: overview != nil,
            hasJourney: journey != nil
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let endpoint {
                    endpointContent(endpoint)
                        .opacity(mode == .scenarios ? 1 : 0)
                        .allowsHitTesting(mode == .scenarios)
                        .accessibilityHidden(mode != .scenarios)
                }
                switch mode {
                case .journey:
                    if let journey { JourneyInspector(context: journey).id(journey.selected.id) }
                case .overview:
                    if let overview { InspectorOverview(summary: overview, onShowJourneys: onShowJourneys) }
                case .empty:
                    DSEmptyState(heading: "No selection", message: "Select an endpoint or journey to inspect it.",
                                 prominence: .compact, identifier: "inspector.empty")
                case .scenarios:
                    EmptyView()
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar { headerToolbar }
        .sheet(item: $addScenarioTarget) { target in
            NewScenarioSheet { name in onAddScenario(target.id, name) }
        }
    }

    /// The header: the mode's title at the leading edge of the inspector's toolbar section and its
    /// action at the trailing edge, level with the window's toolbar as the design draws it.
    @ToolbarContentBuilder
    private var headerToolbar: some ToolbarContent {
        if showsHeader {
            ToolbarItem(id: "inspector.header") {
                headerTitle
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)

            if mode == .journey, let journey {
                ToolbarItem(id: "inspector.stepActions") {
                    JourneyStepActionsMenu(context: journey)
                }
                .sharedBackgroundVisibility(.hidden)
            }

            if mode == .scenarios, endpoint != nil {
                ToolbarItem(id: "inspector.addScenario") {
                    DSPanelHeaderButton(systemImage: "plus", help: "Add scenario",
                                        identifier: "inspector.addScenarioButton") {
                        addScenarioTarget = endpoint.map { ScenarioTarget(id: $0.id) }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: DSSpacing.xs) {
            // A selected journey step names itself, "Step 3", as the design's inspector does.
            Text(mode == .journey ? (journey?.title ?? mode.title) : mode.title)
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("ds.panelheader.title.inspector")
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.leading, DSSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.header")
    }

    private func endpointContent(_ endpoint: Endpoint) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScenarioListView(
                    endpoint: endpoint,
                    editedScenarioID: endpointSettings?.editedScenarioID ?? endpoint.activeScenarioID,
                    onSetActive: onSetActiveScenario,
                    onDuplicate: onDuplicateScenario, onDelete: onDeleteScenario,
                    onRename: onRenameScenario,
                    onEdit: endpointSettings?.onEditScenario ?? { _, _ in }
                )
                HStack(spacing: 6) {
                    DSLiveIndicator(isLive: true, size: 10)
                    Text("Live scenario, served on every request")
                }
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .padding(.horizontal, DSInspectorMetrics.inset)
                .padding(.top, DSSpacing.sm)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inspector.liveNote")

                if let endpointSettings {
                    EndpointInspectorSettings(endpoint: endpoint, context: endpointSettings)
                }

                EndpointTrafficSummary(logs: endpointTraffic, onSelect: onSelectTrafficLog)
            }
            .padding(.bottom, DSSpacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.endpointIdentity")
        .accessibilityLabel("\(endpoint.method.rawValue) method \(endpoint.path)")
    }
}

/// The endpoint's scenarios. The radio makes one live; clicking a row opens it in the editor.
struct ScenarioListView: View {
    let endpoint: Endpoint
    var editedScenarioID: UUID?
    let onSetActive: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicate: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDelete: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    var onRename: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in }
    var onEdit: (_ endpointID: UUID, _ scenarioID: UUID) -> Void = { _, _ in }
    @State private var renameTarget: Scenario?

    var body: some View {
        VStack(spacing: DSSpacing.xxs) {
            ForEach(endpoint.scenarios) { scenario in
                ScenarioRow(
                    scenario: scenario,
                    isActive: scenario.id == endpoint.activeScenarioID,
                    isEdited: scenario.id == (editedScenarioID ?? endpoint.activeScenarioID),
                    isOnlyScenario: endpoint.scenarios.count == 1,
                    onTap: { onEdit(endpoint.id, scenario.id) },
                    onMakeLive: { onSetActive(endpoint.id, scenario.id) },
                    onRename: { renameTarget = scenario },
                    onDuplicate: { onDuplicate(endpoint.id, scenario.id) },
                    onDelete: { onDelete(endpoint.id, scenario.id) }
                )
            }
        }
        .padding(.horizontal, DSInspectorMetrics.rowInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.scenarioList")
        .sheet(item: $renameTarget) { scenario in
            RenameItemSheet(
                title: "Rename scenario", fieldLabel: "Scenario name",
                identifier: "scenarioRename", initialName: scenario.name
            ) { name in
                onRename(endpoint.id, scenario.id, name)
            }
        }
    }
}

struct ScenarioRow: View {
    let scenario: Scenario
    let isActive: Bool
    var isEdited: Bool = false
    let isOnlyScenario: Bool
    let onTap: () -> Void
    var onMakeLive: () -> Void = {}
    var onRename: () -> Void = {}
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onMakeLive) {
                DSLiveIndicator(isLive: isActive)
                    .frame(width: 20, height: DSRowHeight.list)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive ? "Live" : "Make live")
            .accessibilityIdentifier("inspector.scenario.\(scenario.name).live")
            .accessibilityLabel(isActive ? "\(scenario.name) is live" : "Make \(scenario.name) live")

            Button(action: onTap) {
                HStack(spacing: DSSpacing.sm) {
                    Text(scenario.name)
                        .font(isEdited ? DSTypography.bodyMedium : DSTypography.body)
                        .foregroundStyle(DSColors.labelPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DSStatusLabel(statusCode: scenario.statusCode)
                }
                .frame(height: DSRowHeight.list)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.spokenLabel(scenario: scenario, isActive: isActive))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(rowTraits)
            .accessibilityIdentifier("inspector.scenario.\(scenario.name)")
            .accessibilityLabel(Self.spokenLabel(scenario: scenario, isActive: isActive))
            .accessibilityValue(isActive ? "active" : "inactive")
        }
        .padding(.leading, DSSpacing.xs)
        .padding(.trailing, DSSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.field, style: .continuous)
                .fill(isEdited ? DSColors.selectionSoft : (isHovered ? DSColors.hover : Color.clear))
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if !isActive {
                Button(action: onMakeLive) { Label("Make live", systemImage: "dot.radiowaves.left.and.right") }
                    .accessibilityIdentifier("inspector.scenario.contextMenu.makeLive")
                Divider()
            }
            Button(action: onRename) { Label("Rename\u{2026}", systemImage: "pencil") }
                .accessibilityIdentifier("inspector.scenario.contextMenu.rename")
            Button(action: onDuplicate) { Label("Duplicate", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("inspector.scenario.contextMenu.duplicate")
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete scenario", systemImage: "trash") }
                .disabled(isOnlyScenario)
                .accessibilityIdentifier("inspector.scenario.contextMenu.delete")
        }
    }

    var rowTraits: AccessibilityTraits {
        isEdited ? [.isButton, .isSelected] : .isButton
    }

    nonisolated static func spokenLabel(scenario: Scenario, isActive: Bool) -> String {
        "\(scenario.name), status \(scenario.statusCode)\(isActive ? ", active" : "")"
    }
}

struct NewScenarioSheet: View {
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Which field the sheet opens on. Typing has to work the moment the sheet appears; making the
    /// user click into the first field first is a step macOS never asks for.
    private enum Field: Hashable {
        case name
    }

    @State private var name = ""
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("New scenario")
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)

            // No `.accessibilityLabel` on the wrapper: `DSTextField` already labels its own input,
            // and a label here would shadow the validation text it shows underneath.
            DSTextField(
                "Name",
                text: $name,
                placeholder: "e.g. Unauthorized",
                identifier: "newScenario.name"
            )
            .accessibilityIdentifier("newScenario.nameField")
            .focused($focusedField, equals: .name)
            .onSubmit(confirmIfValid)

            HStack(spacing: DSSpacing.sm) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .secondary,
                    size: .large,
                    identifier: "newScenario.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("newScenario.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Add scenario",
                    variant: .primary,
                    size: .large,
                    identifier: "newScenario.create",
                    action: confirmIfValid
                )
                .accessibilityIdentifier("newScenario.createButton")
                .accessibilityLabel("Add scenario")
                // Read through the same sanitizer the confirm path uses, so the button cannot be
                // enabled for a name `performConfirm` would then reject.
                .disabled(Self.sanitizedName(from: name) == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
        .background(DSColors.sheet)
        .defaultFocus($focusedField, .name)
    }

    func confirmIfValid() {
        Self.performConfirm(rawName: name, onConfirm: onConfirm, dismiss: dismiss.callAsFunction)
    }

    static func sanitizedName(from rawName: String) -> String? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    static func performConfirm(rawName: String, onConfirm: (String) -> Void, dismiss: () -> Void) {
        guard let trimmedName = sanitizedName(from: rawName) else { return }
        dismiss()
        onConfirm(trimmedName)
    }
}
