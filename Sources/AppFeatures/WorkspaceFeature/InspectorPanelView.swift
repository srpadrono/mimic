import SwiftUI
import Domain
import DesignSystem

/// Inspector for the current selection. Request details temporarily cover the selected endpoint
/// or journey; returning restores that context. With no selection the project overview is shown.
struct InspectorPanelView: View {
    /// The logged request to show. Takes precedence over `endpoint` and `overview` when set.
    let requestDetail: RequestDetailInspector.Context?
    let endpoint: Endpoint?
    let journey: JourneyInspector.Context?
    let selectedRequestCount: Int
    /// Project-level facts, shown when nothing is selected so the panel is never dead space.
    let overview: InspectorOverview.Summary?
    let onSaveAsMock: ((UUID) -> Void)?
    let onShowJourneys: () -> Void
    let onCloseRequestDetail: () -> Void
    let onAddScenario: (_ endpointID: UUID, _ name: String) -> Void
    let onSetActiveScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicateScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDeleteScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onRenameScenario: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void
    /// Every request the selected endpoint answered. Already filtered by the caller.
    let endpointTraffic: [RequestLog]
    /// Opens one of those requests in the request detail.
    let onSelectTrafficLog: (UUID) -> Void

    /// The endpoint the add-scenario sheet is adding to, captured when the sheet opens.
    ///
    /// Not a `Bool` read back against `endpoint`. The sheet used to be
    /// `.sheet(isPresented:) { if let endpoint { … } }`, which is fine right up until the endpoint
    /// stops existing while the sheet is up — and in this app it can: the control plane and the
    /// `mimic` CLI drive the same store the window does, so `mimic endpoint delete` lands whether or
    /// not a sheet is open. The `if let` then produced an `EmptyView`, which presents as a blank
    /// sheet with no controls at all — including no cancel button, since Escape was bound inside the
    /// view that no longer exists. Carrying the id makes the sheet a function of what was clicked
    /// rather than of what is still selected.
    @State private var addScenarioTarget: ScenarioTarget?
    @State private var endpointTab: EndpointTab = .scenarios
    @State private var requestDetailTab: RequestDetailTab = .summary

    /// `sheet(item:)` wants an `Identifiable`, and a bare `UUID` is not one.
    struct ScenarioTarget: Identifiable {
        let id: UUID
    }

    /// Which question the inspector is answering about the selected endpoint.
    ///
    /// Xcode's inspector does this: same selection, several tabs, because "what is this" and "what
    /// has happened to this" are different questions. Mimic already recorded which endpoint answered
    /// each request — `RequestLog.matchedEndpointID` — but never offered a way to ask. Finding out
    /// whether anything had actually called the endpoint in front of you meant going to the log and
    /// filtering by hand.
    enum EndpointTab: String, CaseIterable, Identifiable {
        case scenarios
        case traffic

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .scenarios: "square.stack.3d.up"
            case .traffic: "waveform.path.ecg"
            }
        }

        var title: String {
            switch self {
            case .scenarios: "Scenarios"
            case .traffic: "Traffic"
            }
        }

        var help: String {
            switch self {
            case .scenarios: "Show this endpoint's scenarios"
            case .traffic: "Show the requests this endpoint answered"
            }
        }
    }

    public init(
        endpoint: Endpoint?,
        requestDetail: RequestDetailInspector.Context? = nil,
        overview: InspectorOverview.Summary? = nil,
        journey: JourneyInspector.Context? = nil,
        selectedRequestCount: Int = 0,
        endpointTraffic: [RequestLog] = [],
        onShowJourneys: @escaping () -> Void = {},
        onCloseRequestDetail: @escaping () -> Void = {},
        onSelectTrafficLog: @escaping (UUID) -> Void = { _ in },
        onAddScenario: @escaping (_ endpointID: UUID, _ name: String) -> Void,
        onSetActiveScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDuplicateScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDeleteScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onRenameScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in },
        onSaveAsMock: ((UUID) -> Void)? = nil,
        initialEndpointTab: EndpointTab = .scenarios
    ) {
        self.onSaveAsMock = onSaveAsMock
        self.endpoint = endpoint
        self.requestDetail = requestDetail
        self.overview = overview
        self.journey = journey
        self.selectedRequestCount = selectedRequestCount
        self.endpointTraffic = endpointTraffic
        self.onShowJourneys = onShowJourneys
        self.onCloseRequestDetail = onCloseRequestDetail
        self.onSelectTrafficLog = onSelectTrafficLog
        self.onAddScenario = onAddScenario
        self.onSetActiveScenario = onSetActiveScenario
        self.onDuplicateScenario = onDuplicateScenario
        self.onDeleteScenario = onDeleteScenario
        self.onRenameScenario = onRenameScenario
        _endpointTab = State(initialValue: initialEndpointTab)
    }

    /// What the panel is showing, so the header and the content cannot disagree about it.
    enum Mode: Equatable {
        case request
        case scenarios
        case journey
        case selection
        case overview
        case empty

        var title: String {
            switch self {
            case .request: "Request"
            case .scenarios: "Scenarios"
            case .journey: "Journey"
            case .selection: "Requests"
            case .overview: "Overview"
            case .empty: "Inspector"
            }
        }
    }

    static func mode(
        hasRequestDetail: Bool,
        hasEndpoint: Bool,
        hasOverview: Bool,
        hasJourney: Bool = false,
        selectedRequestCount: Int = 0
    ) -> Mode {
        if hasRequestDetail { return .request }
        if selectedRequestCount > 1 { return .selection }
        if hasEndpoint { return .scenarios }
        if hasJourney { return .journey }
        if hasOverview { return .overview }
        return .empty
    }

    var mode: Mode {
        Self.mode(
            hasRequestDetail: requestDetail != nil,
            hasEndpoint: endpoint != nil,
            hasOverview: overview != nil,
            hasJourney: journey != nil,
            selectedRequestCount: selectedRequestCount
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSInspectorHeader {
                if mode == .scenarios {
                    Picker("Endpoint inspector", selection: $endpointTab) {
                        ForEach(EndpointTab.allCases) { tab in
                            Text(tab == .traffic && !endpointTraffic.isEmpty ? "Traffic · \(endpointTraffic.count)" : tab.title).tag(tab)
                                .help(tab.help)
                                .accessibilityIdentifier("inspector.tab.\(tab.id)")
                                .accessibilityLabel(tab == .traffic ? "\(tab.help), \(endpointTraffic.count) requests" : tab.help)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityIdentifier("inspector.mode")
                    .accessibilityLabel("Endpoint inspector")
                    Spacer(minLength: 0)
                    Group {
                        if endpointTab == .scenarios, let endpoint {
                            DSPanelHeaderButton(systemImage: "plus", help: "Add scenario",
                                                identifier: "inspector.addScenarioButton") {
                                addScenarioTarget = ScenarioTarget(id: endpoint.id)
                            }
                        } else { Color.clear }
                    }
                    .frame(width: DSControlHeight.field, height: DSControlHeight.field)
                } else {
                    if mode == .request {
                        DSPanelHeaderButton(
                            systemImage: "chevron.left",
                            help: endpoint != nil && endpointTab == .traffic ? "Back to traffic" : "Back to selection",
                            identifier: "inspector.closeRequestDetailButton",
                            action: onCloseRequestDetail
                        )
                    }
                    Text(mode.title)
                        .font(DSTypography.controlLabel)
                        .lineLimit(1)
                        .accessibilityIdentifier("ds.panelheader.title.inspector")
                    Spacer(minLength: 0)
                }
            }

            // Keep endpoint content mounted under request details. Returning to Traffic restores
            // the same scroll position instead of constructing a new list at its first request.
            ZStack(alignment: .topLeading) {
                if let endpoint {
                    endpointContent(endpoint)
                        .opacity(mode == .scenarios ? 1 : 0)
                        .allowsHitTesting(mode == .scenarios)
                        .accessibilityHidden(mode != .scenarios)
                }
                switch mode {
                case .request:
                    if let requestDetail {
                        // Rebuild for a different log while keeping the inspector's chosen tab.
                        RequestDetailInspector(
                            context: requestDetail,
                            onSaveAsMock: onSaveAsMock,
                            tabSelection: $requestDetailTab
                        )
                            .id(requestDetail.log.id)
                    }
                case .journey:
                    if let journey { JourneyInspector(context: journey).id(journey.selected.id) }
                case .selection:
                    DSEmptyState(
                        heading: "\(selectedRequestCount) requests selected",
                        message: "Select one request to inspect its headers and body.",
                        identifier: "inspector.multipleRequests"
                    )
                case .overview:
                    if let overview { InspectorOverview(summary: overview, onShowJourneys: onShowJourneys) }
                case .empty:
                    DSEmptyState(heading: "No selection", message: "Select an endpoint or journey to inspect it.",
                                 identifier: "inspector.empty")
                case .scenarios:
                    EmptyView()
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $addScenarioTarget) { target in
            NewScenarioSheet { name in onAddScenario(target.id, name) }
        }
    }

    private func endpointContent(_ endpoint: Endpoint) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DSSpacing.sm) {
                DSMethodBadge(method: endpoint.method.rawValue, size: .compact,
                              identifier: "inspector.endpointMethod")
                Text(endpoint.path)
                    .font(DSTypography.codeSmall)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help("\(endpoint.name) — \(endpoint.method.rawValue) \(endpoint.path)")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSInspectorMetrics.inset)
            .frame(height: DSBarHeight.controlRow)
            // AppKit can retain the selectable path's old accessibility value when the row is
            // reused, including after editing this endpoint's request identity.
            .id("\(endpoint.id)-\(endpoint.method.rawValue)-\(endpoint.path)")
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("inspector.endpointIdentity")
            .accessibilityLabel("\(endpoint.method.rawValue) method \(endpoint.path)")
            switch endpointTab {
            case .scenarios:
                ScenarioListView(endpoint: endpoint, onSetActive: onSetActiveScenario,
                                 onDuplicate: onDuplicateScenario, onDelete: onDeleteScenario,
                                 onRename: onRenameScenario)
                HStack {
                    Text("\(endpoint.scenarios.count) \(endpoint.scenarios.count == 1 ? "scenario" : "scenarios")")
                    Spacer(minLength: DSSpacing.sm)
                    Text("Click a row to activate")
                }
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .padding(.horizontal, DSInspectorMetrics.inset)
                .frame(height: DSInspectorMetrics.footerHeight)
                .overlay(alignment: .top) {
                    Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
                }
            case .traffic:
                EndpointTrafficList(logs: endpointTraffic, onSelect: onSelectTrafficLog)
            }
        }
    }
}

/// List of scenarios for an endpoint with active indicator and context menu.
struct ScenarioListView: View {
    let endpoint: Endpoint
    let onSetActive: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicate: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDelete: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    var onRename: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in }
    @State private var renameTarget: Scenario?

    var body: some View {
        List(endpoint.scenarios) { scenario in
            ScenarioRow(
                scenario: scenario,
                isActive: scenario.id == endpoint.activeScenarioID,
                isOnlyScenario: endpoint.scenarios.count == 1,
                onTap: { onSetActive(endpoint.id, scenario.id) },
                onRename: { renameTarget = scenario },
                onDuplicate: { onDuplicate(endpoint.id, scenario.id) },
                onDelete: { onDelete(endpoint.id, scenario.id) }
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, DSInspectorMetrics.rowHeight)
        .contentMargins(.all, 0, for: .scrollContent)
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

/// One checkmark identifies the active response; status codes share a fixed trailing column.
struct ScenarioRow: View {
    let scenario: Scenario
    let isActive: Bool
    let isOnlyScenario: Bool
    let onTap: () -> Void
    var onRename: () -> Void = {}
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: DSGlyph.control, weight: .semibold))
                    .foregroundStyle(DSColors.accentText)
                    .opacity(isActive ? 1 : 0)
                    .frame(width: DSInspectorMetrics.iconSlot)
                    .accessibilityHidden(true)
                Text(scenario.name)
                    .font(DSTypography.controlLabelQuiet)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DSInspectorStatus(statusCode: scenario.statusCode)
                    .frame(width: DSInspectorMetrics.statusColumn, alignment: .trailing)
            }
            .padding(.horizontal, DSInspectorMetrics.inset)
            .frame(height: DSInspectorMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
        .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
        .help(Self.spokenLabel(scenario: scenario, isActive: isActive))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(rowTraits)
        .contextMenu {
            Button(action: onRename) { Label("Rename\u{2026}", systemImage: "pencil") }
                .accessibilityIdentifier("inspector.scenario.contextMenu.rename")
            Button(action: onDuplicate) { Label("Duplicate", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("inspector.scenario.contextMenu.duplicate")
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete scenario", systemImage: "trash") }
                .disabled(isOnlyScenario)
                .accessibilityIdentifier("inspector.scenario.contextMenu.delete")
        }
        .accessibilityIdentifier("inspector.scenario.\(scenario.name)")
        .accessibilityLabel(Self.spokenLabel(scenario: scenario, isActive: isActive))
        .accessibilityValue(isActive ? "active" : "inactive")
    }

    /// The active checkmark also carries a selected trait for assistive technology.
    var rowTraits: AccessibilityTraits {
        isActive ? [.isButton, .isSelected] : .isButton
    }

    /// What VoiceOver reads for the row. `static` so the composition can be pinned without hosting a
    /// window, the way the request log's row label is.
    ///
    /// The active clause is said as well as carried in the trait and the value, because the trait is
    /// what an assistive technology *queries* and this row sits in a plain `List` cell that does not
    /// announce a selection on its behalf.
    nonisolated static func spokenLabel(scenario: Scenario, isActive: Bool) -> String {
        "\(scenario.name), status \(scenario.statusCode)\(isActive ? ", active" : "")"
    }
}

/// Sheet for adding a new scenario.
///
/// Follows the shared sheet convention: a sentence-case heading inside the sheet, `DSSpacing.lg`
/// between the heading, the fields and the button row, `DSSpacing.lg` of outer padding, and a
/// trailing button row with cancel to the left of the confirm action.
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
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

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

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "newScenario.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("newScenario.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    "Add scenario",
                    variant: .primary,
                    size: .medium,
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
        .padding(DSSpacing.lg)
        .frame(minWidth: DSSheetWidth.compact, idealWidth: DSSheetWidth.compact)
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
