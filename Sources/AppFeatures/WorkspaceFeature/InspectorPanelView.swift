import SwiftUI
import Domain
import DesignSystem

/// Inspector panel — request detail, an endpoint's scenarios, or the project overview.
///
/// Three modes, in that precedence order. A selected request wins because selecting one is the more
/// recent, more specific act: you clicked a row in the log expecting to see it, and the endpoint
/// selection that was already there has not gone anywhere. Clearing the log selection puts the
/// endpoint back.
struct InspectorPanelView: View {
    /// The logged request to show. Takes precedence over `endpoint` and `overview` when set.
    let requestDetail: RequestDetailInspector.Context?
    let endpoint: Endpoint?
    /// Project-level facts, shown when nothing is selected so the panel is never dead space.
    let overview: InspectorOverview.Summary?
    let onShowJourneys: () -> Void
    let onCloseRequestDetail: () -> Void
    let onAddScenario: (_ endpointID: UUID, _ name: String) -> Void
    let onSetActiveScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicateScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDeleteScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
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
        endpointTraffic: [RequestLog] = [],
        onShowJourneys: @escaping () -> Void = {},
        onCloseRequestDetail: @escaping () -> Void = {},
        onSelectTrafficLog: @escaping (UUID) -> Void = { _ in },
        onAddScenario: @escaping (_ endpointID: UUID, _ name: String) -> Void,
        onSetActiveScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDuplicateScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDeleteScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        initialEndpointTab: EndpointTab = .scenarios
    ) {
        self.endpoint = endpoint
        self.requestDetail = requestDetail
        self.overview = overview
        self.endpointTraffic = endpointTraffic
        self.onShowJourneys = onShowJourneys
        self.onCloseRequestDetail = onCloseRequestDetail
        self.onSelectTrafficLog = onSelectTrafficLog
        self.onAddScenario = onAddScenario
        self.onSetActiveScenario = onSetActiveScenario
        self.onDuplicateScenario = onDuplicateScenario
        self.onDeleteScenario = onDeleteScenario
        _endpointTab = State(initialValue: initialEndpointTab)
    }

    /// What the panel is showing, so the header and the content cannot disagree about it.
    enum Mode: Equatable {
        case request
        case scenarios
        case overview
        case empty

        var title: String {
            switch self {
            case .request: "Request"
            case .scenarios: "Scenarios"
            case .overview: "Overview"
            case .empty: "Inspector"
            }
        }
    }

    static func mode(
        hasRequestDetail: Bool,
        hasEndpoint: Bool,
        hasOverview: Bool
    ) -> Mode {
        if hasRequestDetail { return .request }
        if hasEndpoint { return .scenarios }
        if hasOverview { return .overview }
        return .empty
    }

    var mode: Mode {
        Self.mode(
            hasRequestDetail: requestDetail != nil,
            hasEndpoint: endpoint != nil,
            hasOverview: overview != nil
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header is present whether or not something is selected, so the panel keeps its
            // identity and stays aligned with the sidebar and the request log. Chrome that vanishes
            // with its content reads as a rendering glitch, and it made the three panels line up
            // differently depending on what you had clicked.
            DSPanelHeader(
                headerTitle,
                subtitle: headerSubtitle,
                identifier: "inspector"
            ) {
                switch mode {
                case .request:
                    // Named "back" rather than "close": it returns the panel to whatever it was
                    // showing, which is not the same as dismissing it.
                    DSPanelHeaderButton(
                        systemImage: "xmark",
                        help: "Back to the endpoint inspector",
                        identifier: "inspector.closeRequestDetailButton",
                        action: onCloseRequestDetail
                    )
                case .scenarios:
                    // The tabs ride in the header rather than in a row of their own. A second 30pt
                    // strip under the title would have cost the inspector a tenth of its height to
                    // say something the title already says.
                    HStack(spacing: DSSpacing.xs) {
                        DSTabStrip(
                            tabs: EndpointTab.allCases.map { tab in
                                DSTabStrip.Tab(
                                    id: tab.id,
                                    systemImage: tab.systemImage,
                                    help: tab.help,
                                    // The count answers "did anything actually call this?" without
                                    // making you switch tabs to find out.
                                    badge: tab == .traffic && !endpointTraffic.isEmpty
                                        ? endpointTraffic.count
                                        : nil
                                )
                            },
                            selection: endpointTabBinding,
                            identifier: "inspector",
                            // No chrome: this strip sits inside a `DSPanelHeader`, which already
                            // draws the bar, the `secondary` surface and the 0.5pt bottom rule.
                            // Drawing them twice composites the hairline with itself — whatever
                            // `DSColors.separator` is, two of it read roughly twice as dark — so the
                            // header's bottom edge was visibly heavier under the tabs than under the
                            // title, with a hard edge at the strip's boundary.
                            drawsChrome: false
                        )
                        .fixedSize()

                        // Only on the tab it acts on — a "+" above a traffic list would have
                        // nothing to add to.
                        if endpointTab == .scenarios, let endpoint {
                            DSPanelHeaderButton(
                                systemImage: "plus",
                                help: "Add scenario",
                                identifier: "inspector.addScenarioButton"
                            ) {
                                addScenarioTarget = ScenarioTarget(id: endpoint.id)
                            }
                        }
                    }
                case .overview, .empty:
                    EmptyView()
                }
            }

            switch mode {
            case .request:
                if let requestDetail {
                    RequestDetailInspector(context: requestDetail)
                }
            case .scenarios:
                if let endpoint {
                    switch endpointTab {
                    case .scenarios:
                        ScenarioListView(
                            endpoint: endpoint,
                            onSetActive: onSetActiveScenario,
                            onDuplicate: onDuplicateScenario,
                            onDelete: onDeleteScenario
                        )
                    case .traffic:
                        EndpointTrafficList(
                            logs: endpointTraffic,
                            onSelect: onSelectTrafficLog
                        )
                    }
                }
            case .overview:
                if let overview {
                    InspectorOverview(summary: overview, onShowJourneys: onShowJourneys)
                }
            case .empty:
                DSEmptyState(
                    heading: "No selection",
                    message: "Select an endpoint to view its details and scenarios.",
                    identifier: "inspector.empty"
                )
            }
        }
        .sheet(item: $addScenarioTarget) { target in
            NewScenarioSheet { name in
                onAddScenario(target.id, name)
            }
        }
    }

    /// What the header calls the panel. With an endpoint selected the tab is the more specific
    /// answer, so it wins — a header reading "Scenarios" above a list of requests would be a lie.
    private var headerTitle: String {
        mode == .scenarios ? endpointTab.title : mode.title
    }

    /// `DSTabStrip` speaks in raw ids so it can live in the design system without knowing what an
    /// inspector is; the enum stays on this side of that boundary.
    private var endpointTabBinding: Binding<String> {
        Binding(
            get: { endpointTab.id },
            set: { endpointTab = EndpointTab(rawValue: $0) ?? .scenarios }
        )
    }

    /// The path of whatever the panel is describing — but only where the panel does not already say
    /// it.
    ///
    /// `.request` carries none. `RequestDetailInspector` opens with an identity row — method badge,
    /// status, time, then the path in code voice — and a subtitle of "GET /health" put that same
    /// string on screen twice inside 40pt, the second time directly beneath the first. Repetition
    /// that close reads as a rendering fault rather than as emphasis.
    ///
    /// `.scenarios` keeps its path: the scenario rows below it name scenarios, not the endpoint, so
    /// the subtitle is the only thing saying which endpoint they belong to.
    private var headerSubtitle: String? {
        switch mode {
        case .request: nil
        case .scenarios: endpoint?.path
        case .overview, .empty: nil
        }
    }
}

/// List of scenarios for an endpoint with active indicator and context menu.
struct ScenarioListView: View {
    let endpoint: Endpoint
    let onSetActive: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicate: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDelete: (_ endpointID: UUID, _ scenarioID: UUID) -> Void

    var body: some View {
        List(endpoint.scenarios) { scenario in
            ScenarioRow(
                scenario: scenario,
                isActive: scenario.id == endpoint.activeScenarioID,
                isOnlyScenario: endpoint.scenarios.count == 1,
                onTap: { onSetActive(endpoint.id, scenario.id) },
                onDuplicate: { onDuplicate(endpoint.id, scenario.id) },
                onDelete: { onDelete(endpoint.id, scenario.id) }
            )
        }
        .listStyle(.plain)
        .accessibilityIdentifier("inspector.scenarioList")
    }
}

/// Single scenario row — active state with accent left border.
struct ScenarioRow: View {
    let scenario: Scenario
    let isActive: Bool
    let isOnlyScenario: Bool
    let onTap: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            // Active indicator — accent left border style
            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? DSColors.accent : .clear)
                .frame(width: 2, height: 20)

            // One symbol rather than a circle, a stroke and a checkmark stacked by hand. That build
            // put a 7pt glyph inside a 12pt ring — under the 8pt floor, where a checkmark stops
            // being a checkmark and becomes a smudge — and it re-drew a mark AppKit already ships
            // optically corrected at this size.
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                // `controlProminent`, which is `DSTypography.body`'s size — the font the scenario
                // name beside it is set in, so the mark sits level with the line rather than a point
                // proud of it. The 8pt floor the note above invokes is the bottom of this same
                // ladder, named as `DSGlyph.minimum`.
                .font(.system(size: DSGlyph.controlProminent, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DSColors.accentText : DSColors.labelSecondary)
                .accessibilityIdentifier("inspector.scenario.\(scenario.name).indicator")

            Text(scenario.name)
                .font(isActive ? DSTypography.bodyMedium : DSTypography.body)
                .foregroundStyle(isActive ? DSColors.labelPrimary : DSColors.labelSecondary)

            Spacer()

            // Coloured text, and a fill only once the code is one you would want to stop on. This
            // list is a column of scenarios, and most of them answer 200: filling every row put a
            // block of green down the panel that carried no information, because nothing in it was
            // any louder than anything else. Same rule, and the same `>= 400` seam, as the traffic
            // list in `EndpointTrafficList`.
            Text("\(scenario.statusCode)")
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.httpStatusColor(for: scenario.statusCode))
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 1)
                .background {
                    if scenario.statusCode >= 400 {
                        RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                            .fill(DSColors.httpStatusColor(for: scenario.statusCode).opacity(0.12))
                    }
                }

            if isActive {
                Text("Active")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.accentText)
                    .accessibilityIdentifier("inspector.scenario.\(scenario.name).activeLabel")
            }
        }
        .padding(.vertical, DSSpacing.xs)
        // `md`, matching every other row in this panel — the overview's rows, the request detail's
        // summary rows and its header rows are all inset 12. At `xs` the whole content of the
        // inspector shifted 8pt left when you switched to Scenarios, under a header that did not
        // move.
        .padding(.horizontal, DSSpacing.md)
        .contentShape(Rectangle())
        .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        // After the element is formed, not before it — `EndpointTrafficRow` orders it the same way,
        // because a trait added to the children is a trait the combine has already passed over.
        //
        // The row activates a scenario on tap, but a tap gesture carries no trait, so VoiceOver
        // announced this as static text with no hint that it could be pressed. `RequestLogTableRow`
        // and `EndpointTrafficRow` are the same shape and already restore it; this row and the
        // journey editor's step row were the two that did not.
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button(action: onDuplicate) { Label("Duplicate", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete scenario", systemImage: "trash") }
                .disabled(isOnlyScenario)
        }
        .accessibilityIdentifier("inspector.scenario.\(scenario.name)")
        .accessibilityLabel("\(scenario.name), status \(scenario.statusCode)\(isActive ? ", active" : "")")
        .accessibilityValue(isActive ? "active" : "inactive")
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
        .frame(minWidth: 420, idealWidth: 420)
        .defaultFocus($focusedField, .name)
    }

    func confirmIfValid() {
        Self.performConfirm(rawName: name, onConfirm: onConfirm, dismiss: dismiss.callAsFunction)
    }

    static func sanitizedName(from rawName: String) -> String? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespaces)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    static func performConfirm(rawName: String, onConfirm: (String) -> Void, dismiss: () -> Void) {
        guard let trimmedName = sanitizedName(from: rawName) else { return }
        dismiss()
        onConfirm(trimmedName)
    }
}
