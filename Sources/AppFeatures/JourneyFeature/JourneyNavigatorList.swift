import DesignSystem
import Domain
import SwiftUI

/// Journey selection and filtering share the endpoint navigator's row geometry.
/// Execution controls live in the editor; selecting a row never activates it.
struct JourneyNavigatorList: View {
    let journeys: [Journey]
    /// The journey currently overriding endpoint responses, if any.
    let activeJourneyID: UUID?
    /// What the centre pane is editing. Selecting is *not* activating — see ``JourneyNavigatorRow``.
    @Binding var selectedJourneyID: UUID?
    /// Pass `nil` to deactivate whatever is running.
    let onActivate: (UUID?) -> Void
    let onAdd: () -> Void
    let onDuplicate: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void

    /// Deleting a journey takes its steps with it and there is no undo anywhere in `AppState`, so
    /// the navigator asks first — as `SidebarView`
    /// does for endpoints. The confirmation lives here rather than at the call site because the
    /// context menu that offers the action lives here.
    @State private var deleteTarget: Journey?
    @State private var renameTarget: Journey?
    @FocusState private var journeyListHasFocus: Bool
    var searchText: String = ""
    @Binding var collapsedGroups: Set<String>

    init(journeys: [Journey], activeJourneyID: UUID?, selectedJourneyID: Binding<UUID?>,
         onActivate: @escaping (UUID?) -> Void, onAdd: @escaping () -> Void,
         onDuplicate: @escaping (UUID) -> Void, onDelete: @escaping (UUID) -> Void,
         onRename: @escaping (UUID, String) -> Void = { _, _ in },
         searchText: String = "", collapsedGroups: Binding<Set<String>> = .constant([])) {
        self.journeys = journeys
        self.activeJourneyID = activeJourneyID
        self._selectedJourneyID = selectedJourneyID
        self.onActivate = onActivate
        self.onAdd = onAdd
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onRename = onRename
        self.searchText = searchText
        self._collapsedGroups = collapsedGroups
    }

    var body: some View {
        VStack(spacing: 0) {
            if journeys.isEmpty {
                // The navigator header stays put above this, so the panel keeps its chrome and
                // its height whichever branch renders. Chrome that disappears with its content reads
                // as a rendering glitch, and it would leave this navigator a row shorter than the
                // endpoint one.
                DSEmptyState(
                    systemImage: NavigatorTab.journeys.systemImage,
                    heading: "No journeys",
                    message: "A journey scripts an ordered sequence of responses, so one endpoint can "
                        + "fail and then succeed on the retry. Add one to script a flow endpoints "
                        + "alone can't express.",
                    // This must stay different from the navigator "+" menu's label above the list
                    // ("Choose how to add a journey", set in `WorkspaceView.addJourneyMenu`). The
                    // two controls do different things: this one creates a journey outright — no
                    // ellipsis, no sheet, straight to `onAdd` — while that one opens a chooser. They
                    // carried the same words until the UI suite was found telling them apart by
                    // AppKit element type, which is a property of a menu style rather than of either
                    // control's identity. `DSEmptyState` speaks this string to VoiceOver as the
                    // button's label, so the copy and the name are the same decision.
                    actionTitle: "Add journey",
                    identifier: "journeys.empty",
                    action: onAdd
                )
            } else {
                List(selection: $selectedJourneyID) {
                    if filteredJourneys.isEmpty {
                        Text("No journeys match your filter")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.labelSecondary)
                            .dsNavigatorRow()
                            .selectionDisabled()
                            .accessibilityIdentifier("journeys.noMatches")
                    }
                    ForEach(groupNames, id: \.self) { name in
                        DSNavigatorGroup(
                            name: name, count: groupedJourneys[name]?.count ?? 0, itemName: "journeys",
                            isCollapsed: collapsedGroups.contains(Self.groupSectionKey(name)),
                            identifier: "journeys.group.\(name)"
                        ) {
                            if collapsedGroups.contains(Self.groupSectionKey(name)) {
                                collapsedGroups.remove(Self.groupSectionKey(name))
                            } else {
                                collapsedGroups.insert(Self.groupSectionKey(name))
                            }
                        }
                        .padding(.top, name == groupNames.first ? 0 : DSSpacing.smPlus)
                        if !collapsedGroups.contains(Self.groupSectionKey(name)) {
                            ForEach(groupedJourneys[name] ?? []) { journey in
                                journeyRow(journey, indented: true)
                            }
                        }
                    }
                    if !groupNames.isEmpty && !ungroupedJourneys.isEmpty {
                        DSNavigatorGroup(
                            name: "Ungrouped", count: ungroupedJourneys.count, itemName: "journeys",
                            isCollapsed: collapsedGroups.contains(Self.ungroupedSectionKey),
                            identifier: "journeys.group.ungrouped"
                        ) {
                            if collapsedGroups.contains(Self.ungroupedSectionKey) {
                                collapsedGroups.remove(Self.ungroupedSectionKey)
                            } else {
                                collapsedGroups.insert(Self.ungroupedSectionKey)
                            }
                        }
                        .padding(.top, DSSpacing.smPlus)
                    }
                    if groupNames.isEmpty || !collapsedGroups.contains(Self.ungroupedSectionKey) {
                        ForEach(ungroupedJourneys) { journey in
                            journeyRow(journey, indented: !groupNames.isEmpty)
                        }
                    }
                }
                .dsNavigatorList()
                // `.contain` keeps the rows addressable by their own identifiers; a bare identifier
                // on a container renames every descendant to match it.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("journeys.list")
                .focused($journeyListHasFocus)
                .onChange(of: selectedJourneyID) { _, selection in
                    if selection != nil { journeyListHasFocus = true }
                }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard !press.modifiers.contains(.command), !press.modifiers.contains(.option) else {
                        return .ignored
                    }
                    let offset = press.key == .downArrow ? 1 : -1
                    guard let next = NavigatorKeyboardSelection.moved(
                        from: selectedJourneyID, by: offset, through: visibleJourneyIDs
                    ) else { return .ignored }
                    selectedJourneyID = next
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let id = selectedJourneyID,
                          visibleJourneyIDs.contains(id),
                          let journey = journeys.first(where: { $0.id == id }) else { return .ignored }
                    renameTarget = journey
                    return .handled
                }
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard let id = selectedJourneyID,
                          visibleJourneyIDs.contains(id),
                          let journey = journeys.first(where: { $0.id == id }) else { return .ignored }
                    deleteTarget = journey
                    return .handled
                }
                .onDeleteCommand {
                    guard let id = selectedJourneyID,
                          visibleJourneyIDs.contains(id) else { return }
                    deleteTarget = journeys.first(where: { $0.id == id })
                }
            }
        }
        .onChange(of: searchText) { _, text in
            if !text.isEmpty {
                collapsedGroups.subtract(groupNames.map(Self.groupSectionKey) + [Self.ungroupedSectionKey])
            }
        }
        .onChange(of: selectedJourneyID) { _, id in
            if let journey = journeys.first(where: { $0.id == id }) {
                collapsedGroups.remove(sectionKey(for: journey))
            }
        }
        .onChange(of: journeys) { old, new in
            let oldSelection = old.first(where: { $0.id == selectedJourneyID })
            if let newSelection = new.first(where: { $0.id == selectedJourneyID }),
               oldSelection == nil || newSelection.groupTag != oldSelection?.groupTag {
                collapsedGroups.remove(sectionKey(for: newSelection))
            }
        }
        .sheet(item: $renameTarget) { journey in
            RenameItemSheet(
                title: "Rename journey", fieldLabel: "Journey name",
                identifier: "journeyRename", initialName: journey.name
            ) { name in
                onRename(journey.id, name)
            }
        }
        .alert(
            "Delete \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { journey in
            Button("Delete", role: .destructive) { onDelete(journey.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the journey and all of its steps. This can't be undone.")
        }
    }

    private var groupedJourneys: [String: [Journey]] {
        Dictionary(grouping: filteredJourneys.filter { !($0.groupTag ?? "").isEmpty }) { $0.groupTag! }
    }

    private var groupNames: [String] { groupedJourneys.keys.sorted() }
    private static let ungroupedSectionKey = "__ungrouped__"
    /// Prefixing named groups keeps a user-entered `__ungrouped__` group distinct from the
    /// ungrouped section's internal collapse state.
    static func groupSectionKey(_ name: String) -> String { "group:\(name)" }
    private var ungroupedJourneys: [Journey] { filteredJourneys.filter { ($0.groupTag ?? "").isEmpty } }

    private var visibleJourneyIDs: [UUID] {
        let grouped = groupNames.flatMap { name in
            collapsedGroups.contains(Self.groupSectionKey(name))
                ? [] : (groupedJourneys[name] ?? []).map(\.id)
        }
        let ungrouped = groupNames.isEmpty || !collapsedGroups.contains(Self.ungroupedSectionKey)
            ? ungroupedJourneys.map(\.id) : []
        return grouped + ungrouped
    }

    private func sectionKey(for journey: Journey) -> String {
        guard let group = journey.groupTag, !group.isEmpty else { return Self.ungroupedSectionKey }
        return Self.groupSectionKey(group)
    }

    private func journeyRow(_ journey: Journey, indented: Bool) -> some View {
        JourneyNavigatorRow(
            journey: journey, isActive: journey.id == activeJourneyID,
            isSelected: journey.id == selectedJourneyID,
            onToggleActivation: { onActivate(journey.id == activeJourneyID ? nil : journey.id) },
            onRename: { renameTarget = journey },
            onDuplicate: { onDuplicate(journey.id) }, onDelete: { deleteTarget = journey }
        )
        .dsNavigatorRow(indented: indented)
        .tag(journey.id)
    }

    private var filteredJourneys: [Journey] {
        guard !searchText.isEmpty else { return journeys }
        return journeys.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.groupTag?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.summary?.localizedCaseInsensitiveContains(searchText) ?? false)
                || $0.steps.contains { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

struct JourneyNavigatorRow: View {
    let journey: Journey
    let isActive: Bool
    var isSelected: Bool = false
    let onToggleActivation: () -> Void
    var onRename: () -> Void = {}
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Image(systemName: isActive ? "play.circle.fill" : NavigatorTab.journeys.systemImage)
                .font(.system(size: DSGlyph.controlProminent))
                .foregroundStyle(isActive && !isSelected ? DSColors.accentText : DSColors.labelSecondary)
                .frame(width: DSNavigatorMetrics.iconSlot)
                .accessibilityHidden(true)

            // Names stay at full contrast whether or not a journey is running: dimming the rest of
            // the list to mark one row would make the other journeys harder to read for no reason.
            Text(journey.name)
                .font(DSTypography.controlLabelQuiet)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)

            Text("· \(stepCountText)")
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .monospacedDigit()
                .fixedSize()
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(accessibilityDescription)
        .contextMenu {
            Button(action: onRename) {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            .accessibilityIdentifier("journeys.contextMenu.rename")

            Button(action: onToggleActivation) {
                Label(
                    isActive ? "Deactivate" : "Activate",
                    systemImage: isActive ? "stop.circle" : "play.circle"
                )
            }
            // One identifier for both wordings: it is one item that toggles, and a test that had to
            // guess which name it currently wears would be asserting on the label anyway.
            .accessibilityIdentifier("journeys.contextMenu.toggleActivation")

            Button(action: onDuplicate) {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("journeys.contextMenu.duplicate")

            Divider()

            // The ellipsis is honest now: `JourneyNavigatorList` presents a confirmation before it
            // calls through. It used to hand `appState.deleteJourney` straight to this button, so a
            // journey and every step in it went in one click, with no undo — while the identical
            // command in the journeys window asked first.
            Button(role: .destructive, action: onDelete) {
                Label("Delete journey\u{2026}", systemImage: "trash")
            }
            .accessibilityIdentifier("journeys.contextMenu.delete")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("journeys.row.\(journey.id.uuidString)")
        .accessibilityLabel(accessibilityDescription)
    }

    private var stepCountText: String {
        "\(journey.steps.count) \(journey.steps.count == 1 ? "step" : "steps")"
    }

    /// Spoken as "Session expiry, 4 steps, active" — the activation state is in the label so a test
    /// can assert that selecting a row did *not* start it.
    private var accessibilityDescription: String {
        "\(journey.name), \(stepCountText), \(isActive ? "active" : "not active")"
    }
}

#if DEBUG
#Preview("Journeys") {
    @Previewable @State var selectedJourneyID: UUID? = nil

    let retry = Journey(
        name: "Retry after failure",
        steps: [
            JourneyStep(
                name: "Login",
                method: .post,
                path: "/login",
                outcome: .respond(JourneyResponse(statusCode: 200))
            ),
            JourneyStep(
                name: "Fails",
                path: "/account-summary",
                outcome: .respond(JourneyResponse(statusCode: 500))
            ),
            JourneyStep(
                name: "Recovers",
                path: "/account-summary",
                outcome: .respond(JourneyResponse(statusCode: 200))
            )
        ]
    )
    let expiry = Journey(
        name: "Session expiry",
        steps: [
            JourneyStep(name: "Stale token", path: "/me", outcome: .respond(JourneyResponse(statusCode: 401)))
        ]
    )
    let scratch = Journey(name: "Scratch flow")

    JourneyNavigatorList(
        journeys: [retry, expiry, scratch],
        activeJourneyID: retry.id,
        selectedJourneyID: $selectedJourneyID,
        onActivate: { _ in },
        onAdd: {},
        onDuplicate: { _ in },
        onDelete: { _ in }
    )
    .frame(width: 260, height: 340)
}

#Preview("Journeys — empty") {
    @Previewable @State var selectedJourneyID: UUID? = nil

    JourneyNavigatorList(
        journeys: [],
        activeJourneyID: nil,
        selectedJourneyID: $selectedJourneyID,
        onActivate: { _ in },
        onAdd: {},
        onDuplicate: { _ in },
        onDelete: { _ in }
    )
    .frame(width: 260, height: 340)
}
#endif
