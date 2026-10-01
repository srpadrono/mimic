import DesignSystem
import Domain
import FeatureSupport
import SwiftUI

/// The inspector's endpoint column: its scenarios, the live note, its settings, and its traffic.
public struct EndpointInspectorContent: View {
    let endpoint: Endpoint
    let endpointTraffic: [RequestLog]
    let endpointSettings: EndpointInspectorSettings.Context?
    let onSetActiveScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicateScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDeleteScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onRenameScenario: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void

    public init(
        endpoint: Endpoint,
        traffic: [RequestLog],
        settings: EndpointInspectorSettings.Context?,
        onSetActiveScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDuplicateScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDeleteScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onRenameScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void
    ) {
        self.endpoint = endpoint
        self.endpointTraffic = traffic
        self.endpointSettings = settings
        self.onSetActiveScenario = onSetActiveScenario
        self.onDuplicateScenario = onDuplicateScenario
        self.onDeleteScenario = onDeleteScenario
        self.onRenameScenario = onRenameScenario
    }

    public var body: some View {
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

                EndpointTrafficSummary(logs: endpointTraffic)
            }
            .padding(.bottom, DSSpacing.lg)
            // On the content group: XCUITest found no element for the identifier on the scroll view.
            // The id makes AppKit drop the old label when the route is edited.
            .id("\(endpoint.id)-\(endpoint.method.rawValue)-\(endpoint.path)")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector.endpointIdentity")
            .accessibilityLabel("\(endpoint.method.rawValue) method \(endpoint.path)")
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The endpoint's scenarios. The radio makes one live; clicking a row opens it in the editor.
public struct ScenarioListView: View {
    let endpoint: Endpoint
    var editedScenarioID: UUID?
    let onSetActive: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicate: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDelete: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    var onRename: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in }
    var onEdit: (_ endpointID: UUID, _ scenarioID: UUID) -> Void = { _, _ in }
    @State private var renameTarget: Scenario?

    public init(
        endpoint: Endpoint,
        editedScenarioID: UUID? = nil,
        onSetActive: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDuplicate: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDelete: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onRename: @escaping (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in },
        onEdit: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void = { _, _ in }
    ) {
        self.endpoint = endpoint
        self.editedScenarioID = editedScenarioID
        self.onSetActive = onSetActive
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onRename = onRename
        self.onEdit = onEdit
    }

    public var body: some View {
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

public struct ScenarioRow: View {
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

    public init(
        scenario: Scenario,
        isActive: Bool,
        isEdited: Bool = false,
        isOnlyScenario: Bool,
        onTap: @escaping () -> Void,
        onMakeLive: @escaping () -> Void = {},
        onRename: @escaping () -> Void = {},
        onDuplicate: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.scenario = scenario
        self.isActive = isActive
        self.isEdited = isEdited
        self.isOnlyScenario = isOnlyScenario
        self.onTap = onTap
        self.onMakeLive = onMakeLive
        self.onRename = onRename
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    public var body: some View {
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

public struct NewScenarioSheet: View {
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Which field the sheet opens on. Typing has to work the moment the sheet appears; making the
    /// user click into the first field first is a step macOS never asks for.
    private enum Field: Hashable {
        case name
    }

    @State private var name = ""
    @FocusState private var focusedField: Field?

    public init(onConfirm: @escaping (String) -> Void) {
        self.onConfirm = onConfirm
    }

    public var body: some View {
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
