import SwiftUI
import Domain
import DesignSystem
import FeatureSupport

/// Sidebar — endpoint list with search filtering and group collapse/expand.
public struct SidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projectName: String?
    let endpoints: [Endpoint]
    let serverConfiguration: ServerConfiguration?
    @Binding var selectedEndpointID: UUID?
    let onDeleteEndpoint: (UUID) -> Void
    let onDuplicateEndpoint: (UUID) -> UUID?
    let onRenameEndpoint: (UUID) -> Void
    let onEditEndpointRequest: (UUID) -> Void
    let onAddEndpoint: () -> Void

    @State private var deleteTarget: EndpointDeleteTarget?
    @Binding private var searchText: String
    /// Which HTTP method the list is restricted to. `Self.anyMethodScopeID` means no restriction.
    @Binding private var methodScopeID: String
    @Binding private var collapsedSections: Set<String>
    @State private var groupedSections: [EndpointGroup] = []
    @State private var ungroupedEndpoints: [Endpoint] = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @FocusState private var endpointListHasFocus: Bool

    struct EndpointDeleteTarget: Identifiable {
        let id: UUID
        let name: String
    }

    public init(
        projectName: String?,
        endpoints: [Endpoint],
        serverConfiguration: ServerConfiguration? = nil,
        selectedEndpointID: Binding<UUID?>,
        onDeleteEndpoint: @escaping (UUID) -> Void,
        onDuplicateEndpoint: @escaping (UUID) -> UUID?,
        onRenameEndpoint: @escaping (UUID) -> Void = { _ in },
        onEditEndpointRequest: @escaping (UUID) -> Void = { _ in },
        onAddEndpoint: @escaping () -> Void,
        searchText: Binding<String> = .constant(""),
        methodScopeID: Binding<String> = .constant(SidebarView.anyMethodScopeID),
        collapsedSections: Binding<Set<String>> = .constant([])
    ) {
        self.init(
            projectName: projectName,
            endpoints: endpoints,
            serverConfiguration: serverConfiguration,
            selectedEndpointID: selectedEndpointID,
            onDeleteEndpoint: onDeleteEndpoint,
            onDuplicateEndpoint: onDuplicateEndpoint,
            onRenameEndpoint: onRenameEndpoint,
            onEditEndpointRequest: onEditEndpointRequest,
            onAddEndpoint: onAddEndpoint,
            initialSearchText: "",
            initialCollapsedSections: []
        )
        self._searchText = searchText
        self._methodScopeID = methodScopeID
        self._collapsedSections = collapsedSections
    }

    init(
        projectName: String?,
        endpoints: [Endpoint],
        serverConfiguration: ServerConfiguration? = nil,
        selectedEndpointID: Binding<UUID?>,
        onDeleteEndpoint: @escaping (UUID) -> Void,
        onDuplicateEndpoint: @escaping (UUID) -> UUID?,
        onRenameEndpoint: @escaping (UUID) -> Void = { _ in },
        onEditEndpointRequest: @escaping (UUID) -> Void = { _ in },
        onAddEndpoint: @escaping () -> Void,
        initialSearchText: String,
        initialCollapsedSections: Set<String>
    ) {
        self.projectName = projectName
        self.endpoints = endpoints
        self.serverConfiguration = serverConfiguration
        self._selectedEndpointID = selectedEndpointID
        self.onDeleteEndpoint = onDeleteEndpoint
        self.onDuplicateEndpoint = onDuplicateEndpoint
        self.onRenameEndpoint = onRenameEndpoint
        self.onEditEndpointRequest = onEditEndpointRequest
        self.onAddEndpoint = onAddEndpoint
        _searchText = .constant(initialSearchText)
        _methodScopeID = .constant(Self.anyMethodScopeID)
        _collapsedSections = .constant(initialCollapsedSections)
        // The first frame lists the endpoints rather than "No endpoints yet": grouping is a pass
        // over the project, cheap enough to do before the list draws.
        let sections = SidebarQuery.sections(endpoints: endpoints, searchText: initialSearchText)
        _groupedSections = State(initialValue: sections.grouped)
        _ungroupedEndpoints = State(initialValue: sections.ungrouped)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if endpoints.isEmpty {
                DSEmptyState(
                    heading: "No endpoints",
                    message: "Endpoints you add or import appear here.",
                    prominence: .compact,
                    identifier: "sidebar.endpoints"
                )
            } else {
                endpointList
            }
        }
        .navigationTitle(projectName ?? "Mimic")
        .frame(minWidth: DSNavigatorMetrics.minimumWidth)
        .onAppear { applySections() }
        .onChange(of: searchText) { _, _ in updateSections(debounce: true) }
        .onChange(of: methodScopeID) { _, _ in updateSections() }
        .onChange(of: endpoints) { _, _ in updateSections() }
        .alert(
            "Delete \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                selectedEndpointID = Self.performDelete(
                    targetID: target.id,
                    selectedEndpointID: selectedEndpointID,
                    onDelete: onDeleteEndpoint
                )
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This will remove the endpoint and all its scenarios. This can't be undone.")
        }
    }

    // MARK: - Endpoint List

    /// Names whichever filter actually emptied the list, so the panel explains itself rather than
    /// just going blank. A method scope with no search term is a real state — and was the one the
    /// old wording could not describe.
    private var noMatchesMessage: String {
        let isScoped = methodScopeID != Self.anyMethodScopeID
        switch (searchText.isEmpty, isScoped) {
        case (false, _):    return "No endpoints match \"\(searchText)\""
        case (true, true):  return "No \(methodScopeID) endpoints"
        case (true, false): return "No endpoints yet"
        }
    }

    @ViewBuilder
    private var endpointList: some View {
        List(selection: $selectedEndpointID) {
            if groupedSections.isEmpty && ungroupedEndpoints.isEmpty {
                Text(noMatchesMessage)
                    .lineLimit(1)
                    .help(noMatchesMessage)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .dsNavigatorRow()
                    .selectionDisabled()
                    .accessibilityIdentifier("sidebar.noMatches")
            } else {
                ForEach(groupedSections, id: \.name) { section in
                    groupRow(section)
                        .padding(.top, section.name == groupedSections.first?.name ? 0 : DSSpacing.sm)
                    if !collapsedSections.contains(Self.groupSectionKey(section.name)) {
                        ForEach(section.endpoints) { endpoint in
                            endpointRow(endpoint, indented: false)
                        }
                    }
                }
                if !groupedSections.isEmpty && !ungroupedEndpoints.isEmpty {
                    DSNavigatorGroup(
                        name: "Ungrouped", count: ungroupedEndpoints.count, itemName: "endpoints",
                        isCollapsed: collapsedSections.contains(Self.ungroupedSectionKey),
                        identifier: "sidebar.group.ungrouped"
                    ) { toggleSection(Self.ungroupedSectionKey) }
                    .padding(.top, DSSpacing.sm)
                }
                if groupedSections.isEmpty || !collapsedSections.contains(Self.ungroupedSectionKey) {
                    ForEach(ungroupedEndpoints) { endpoint in
                        endpointRow(endpoint, indented: false)
                    }
                }
            }
        }
        .dsNavigatorList()
        .accessibilityIdentifier("sidebar.endpointList")
        .focused($endpointListHasFocus)
        .onChange(of: selectedEndpointID) { _, selection in
            if selection != nil { endpointListHasFocus = true }
        }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.option) else {
                return .ignored
            }
            let offset = press.key == .downArrow ? 1 : -1
            guard let next = NavigatorKeyboardSelection.moved(
                from: selectedEndpointID, by: offset, through: visibleEndpointIDs
            ) else { return .ignored }
            selectedEndpointID = next
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = selectedEndpointID, visibleEndpointIDs.contains(id) else { return .ignored }
            onRenameEndpoint(id)
            return .handled
        }
        .onDeleteCommand {
            guard let id = selectedEndpointID,
                  visibleEndpointIDs.contains(id),
                  let endpoint = endpoints.first(where: { $0.id == id }) else { return }
            deleteTarget = Self.deleteTarget(for: endpoint)
        }
    }

    private var visibleEndpointIDs: [UUID] {
        let grouped = groupedSections.flatMap { section in
            collapsedSections.contains(Self.groupSectionKey(section.name))
                ? [] : section.endpoints.map(\.id)
        }
        let ungrouped = groupedSections.isEmpty || !collapsedSections.contains(Self.ungroupedSectionKey)
            ? ungroupedEndpoints.map(\.id) : []
        return grouped + ungrouped
    }

    private func endpointRow(_ endpoint: Endpoint, indented: Bool) -> some View {
        EndpointSidebarRow(
            endpoint: endpoint,
            isSelected: endpoint.id == selectedEndpointID,
            backendName: Self.backendNameForAmbiguousRoute(
                endpoint, among: endpoints, configuration: serverConfiguration
            ),
            showsName: endpoints.contains {
                $0.id != endpoint.id && $0.method == endpoint.method && $0.path == endpoint.path
                    && $0.graphqlOperation == endpoint.graphqlOperation
            }
        )
        .dsNavigatorRow(indented: indented)
        .tag(endpoint.id)
        .contextMenu { endpointContextMenu(endpoint) }
    }

    /// Identical method/path rows on different listeners need a visible owner. Show the server
    /// only for those collisions so the common single-backend list stays compact.
    static func backendNameForAmbiguousRoute(
        _ endpoint: Endpoint, among endpoints: [Endpoint], configuration: ServerConfiguration?
    ) -> String? {
        guard let configuration, configuration.listeners.count > 1 else { return nil }
        let backendID = endpoint.backendID ?? ServerConfiguration.primaryID
        guard endpoints.contains(where: {
            $0.id != endpoint.id && $0.method == endpoint.method && $0.path == endpoint.path
                && $0.graphqlOperation == endpoint.graphqlOperation
                && ($0.backendID ?? ServerConfiguration.primaryID) != backendID
        }) else { return nil }
        return configuration.backend(id: endpoint.backendID)?.name
    }

    private func groupRow(_ section: EndpointGroup) -> some View {
        DSNavigatorGroup(
            name: section.name, count: section.endpoints.count, itemName: "endpoints",
            isCollapsed: collapsedSections.contains(Self.groupSectionKey(section.name)),
            identifier: "sidebar.group.\(section.name)"
        ) { toggleSection(Self.groupSectionKey(section.name)) }
    }

    private static let ungroupedSectionKey = "__ungrouped__"
    /// Named groups and the ungrouped section use disjoint keys, including when a person names a
    /// group `__ungrouped__`.
    static func groupSectionKey(_ name: String) -> String { "group:\(name)" }

    public static func sectionKey(for endpoint: Endpoint) -> String {
        guard let group = endpoint.groupTag, !group.isEmpty else { return ungroupedSectionKey }
        return groupSectionKey(group)
    }

    @ViewBuilder
    private func endpointContextMenu(_ endpoint: Endpoint) -> some View {
        Button("Rename\u{2026}", systemImage: "pencil") { onRenameEndpoint(endpoint.id) }
            .accessibilityIdentifier("sidebar.contextMenu.rename")
        Button("Edit request\u{2026}", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
            onEditEndpointRequest(endpoint.id)
        }
        .accessibilityIdentifier("sidebar.contextMenu.editRequest")
        Divider()
        Button {
            selectedEndpointID = Self.performDuplicate(endpointID: endpoint.id, onDuplicate: onDuplicateEndpoint)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("sidebar.contextMenu.duplicate")
        Divider()
        Button(role: .destructive) {
            deleteTarget = Self.deleteTarget(for: endpoint)
        } label: {
            Label("Delete endpoint\u{2026}", systemImage: "trash")
        }
        .accessibilityIdentifier("sidebar.contextMenu.delete")
    }

    private func toggleSection(_ name: String) {
        let isExpanded = collapsedSections.contains(name)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: DSAnimation.normal)) {
            collapsedSections = Self.updatedCollapsedSections(
                collapsedSections,
                name: name,
                isExpanded: isExpanded
            )
        }
    }

    // MARK: - Data

    /// Regroups straight away, for the bindings the list appears with. Typing goes through
    /// `updateSections(debounce:)` instead, so a long project doesn't regroup on every keystroke.
    private func applySections() {
        searchDebounceTask?.cancel()
        let result = SidebarQuery.sections(
            endpoints: endpoints,
            searchText: searchText,
            methodScopeID: methodScopeID
        )
        groupedSections = result.grouped
        ungroupedEndpoints = result.ungrouped
    }

    private func updateSections(debounce: Bool = false) {
        searchDebounceTask?.cancel()
        
        let currentEndpoints = endpoints
        let currentText = searchText
        let currentScope = methodScopeID

        searchDebounceTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            if Task.isCancelled { return }
            
            let result = await Task.detached {
                SidebarQuery.sections(
                    endpoints: currentEndpoints,
                    searchText: currentText,
                    methodScopeID: currentScope
                )
            }.value
            
            if !Task.isCancelled {
                self.groupedSections = result.grouped
                self.ungroupedEndpoints = result.ungrouped
            }
        }
    }

    static func clearedSearchText() -> String { "" }

    static func deleteTarget(for endpoint: Endpoint) -> EndpointDeleteTarget {
        EndpointDeleteTarget(id: endpoint.id, name: endpoint.name)
    }

    static func performDuplicate(endpointID: UUID, onDuplicate: (UUID) -> UUID?) -> UUID? {
        onDuplicate(endpointID)
    }

    static func performDelete(targetID: UUID, selectedEndpointID: UUID?, onDelete: (UUID) -> Void) -> UUID? {
        let nextSelection = nextSelectionAfterDeleting(selectedEndpointID: selectedEndpointID, targetID: targetID)
        onDelete(targetID)
        return nextSelection
    }

    static func nextSelectionAfterDeleting(selectedEndpointID: UUID?, targetID: UUID) -> UUID? {
        selectedEndpointID == targetID ? nil : selectedEndpointID
    }

    static func updatedCollapsedSections(_ collapsedSections: Set<String>, name: String, isExpanded: Bool) -> Set<String> {
        var updatedSections = collapsedSections
        if isExpanded {
            updatedSections.remove(name)
        } else {
            updatedSections.insert(name)
        }
        return updatedSections
    }

    struct EndpointGroup {
        let name: String
        let endpoints: [Endpoint]
    }
}

extension SidebarView {
    /// The scope that applies no restriction. A sentinel rather than an optional so the scope
    /// control always has something selected — a blank scope reads as broken.
    ///
    /// `nonisolated` so it can be the default argument of `SidebarQuery.sections`, which is pure and
    /// runs off the main actor.
    public nonisolated static let anyMethodScopeID = "any"

    /// Scope options for the filter bar. Only the methods an endpoint can actually be, plus "Any".
    public static var methodScopes: [DSFilterField.Scope] {
        [DSFilterField.Scope(id: anyMethodScopeID, title: "Any")]
            + HTTPMethod.allCases.map {
                DSFilterField.Scope(id: $0.rawValue, title: $0.rawValue)
            }
    }
}

enum SidebarQuery {
    nonisolated static func sections(
        endpoints: [Endpoint],
        searchText: String,
        methodScopeID: String = SidebarView.anyMethodScopeID
    ) -> (grouped: [SidebarView.EndpointGroup], ungrouped: [Endpoint]) {
        var filteredEndpoints = endpoints

        // Scope first: it is the coarser cut, so the text search runs over less.
        if methodScopeID != SidebarView.anyMethodScopeID {
            filteredEndpoints = filteredEndpoints.filter { $0.method.rawValue == methodScopeID }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            filteredEndpoints = filteredEndpoints.filter { endpoint in
                endpoint.name.lowercased().contains(query)
                    || endpoint.path.lowercased().contains(query)
                    || endpoint.method.rawValue.lowercased().contains(query)
                    || (endpoint.graphqlOperation?.lowercased().contains(query) ?? false)
            }
        }

        let grouped = Dictionary(grouping: filteredEndpoints.filter {
            guard let groupTag = $0.groupTag else { return false }
            return !groupTag.isEmpty
        }) { $0.groupTag! }

        // Groups keep the project's order, the order their first endpoint appears in, as the
        // design lists them. A new group goes to the bottom.
        let sections = NavigatorGroupOrder.names(in: filteredEndpoints.map(\.groupTag)).compactMap { groupName in
            grouped[groupName].map { SidebarView.EndpointGroup(name: groupName, endpoints: $0) }
        }
        let ungrouped = filteredEndpoints.filter {
            guard let groupTag = $0.groupTag else { return true }
            return groupTag.isEmpty
        }

        return (sections, ungrouped)
    }
}

/// Compact method and route, with names shown when otherwise identical routes need disambiguation.
struct EndpointSidebarRow: View {
    let endpoint: Endpoint
    var isSelected: Bool = false
    var backendName: String? = nil
    var showsName: Bool = false

    nonisolated static func subtitle(for endpoint: Endpoint) -> String? {
        let name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let restatements = [
            endpoint.path,
            "\(endpoint.method.rawValue) \(endpoint.path)",
        ]
        guard !restatements.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        return name
    }

    /// The live scenario's status, shown only when it is not a success: a row that serves an
    /// error or a redirect says so without opening it.
    nonisolated static func liveStatusCode(for endpoint: Endpoint) -> Int? {
        guard let live = endpoint.scenarios.first(where: { $0.id == endpoint.activeScenarioID }),
              !(200..<300).contains(live.statusCode) else { return nil }
        return live.statusCode
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            DSMethodLabel(endpoint.method.rawValue, fixedWidth: false,
                          identifier: "navigator.\(endpoint.id.uuidString)")
                .frame(width: 46, alignment: .leading)

            Text(endpoint.graphqlOperation.flatMap { $0.isEmpty ? nil : $0 } ?? endpoint.path)
                .font(DSTypography.code)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let metadata = backendName ?? (showsName ? Self.subtitle(for: endpoint) : nil) {
                Text(metadata)
                    .font(DSTypography.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(DSColors.labelSecondary))
                    .lineLimit(1)
                    .frame(maxWidth: 88, alignment: .trailing)
                    .layoutPriority(1)
            }

            if let status = Self.liveStatusCode(for: endpoint) {
                DSStatusLabel(statusCode: status)
                    .scaleEffect(0.92, anchor: .trailing)
            }
        }
        .help("\(endpoint.method.rawValue) \(endpoint.path)\n\(endpoint.name)"
            + (endpoint.graphqlOperation.map { "\n\($0)" } ?? "")
            + (backendName.map { "\nServer: \($0)" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("endpoint-\(endpoint.id.uuidString)")
        .accessibilityLabel("\(endpoint.method.rawValue) \(endpoint.path), \(endpoint.name)"
            + (endpoint.graphqlOperation.map { ", \($0)" } ?? "")
            + (backendName.map { ", server \($0)" } ?? ""))
    }
}
