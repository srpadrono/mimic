import SwiftUI
import Domain
import DesignSystem

/// Sidebar — endpoint list with search filtering and group collapse/expand.
struct SidebarView: View {
    let projectName: String?
    let endpoints: [Endpoint]
    @Binding var selectedEndpointID: UUID?
    let onDeleteEndpoint: (UUID) -> Void
    let onDuplicateEndpoint: (UUID) -> UUID?
    let onAddEndpoint: () -> Void

    @State private var deleteTarget: EndpointDeleteTarget?
    @State private var searchText = ""
    /// Which HTTP method the list is restricted to. `Self.anyMethodScopeID` means no restriction.
    @State private var methodScopeID = SidebarView.anyMethodScopeID
    @State private var collapsedSections: Set<String> = []
    @State private var groupedSections: [EndpointGroup] = []
    @State private var ungroupedEndpoints: [Endpoint] = []
    @State private var searchDebounceTask: Task<Void, Never>?

    struct EndpointDeleteTarget: Identifiable {
        let id: UUID
        let name: String
    }

    public init(
        projectName: String?,
        endpoints: [Endpoint],
        selectedEndpointID: Binding<UUID?>,
        onDeleteEndpoint: @escaping (UUID) -> Void,
        onDuplicateEndpoint: @escaping (UUID) -> UUID?,
        onAddEndpoint: @escaping () -> Void
    ) {
        self.init(
            projectName: projectName,
            endpoints: endpoints,
            selectedEndpointID: selectedEndpointID,
            onDeleteEndpoint: onDeleteEndpoint,
            onDuplicateEndpoint: onDuplicateEndpoint,
            onAddEndpoint: onAddEndpoint,
            initialSearchText: "",
            initialCollapsedSections: []
        )
    }

    init(
        projectName: String?,
        endpoints: [Endpoint],
        selectedEndpointID: Binding<UUID?>,
        onDeleteEndpoint: @escaping (UUID) -> Void,
        onDuplicateEndpoint: @escaping (UUID) -> UUID?,
        onAddEndpoint: @escaping () -> Void,
        initialSearchText: String,
        initialCollapsedSections: Set<String>
    ) {
        self.projectName = projectName
        self.endpoints = endpoints
        self._selectedEndpointID = selectedEndpointID
        self.onDeleteEndpoint = onDeleteEndpoint
        self.onDuplicateEndpoint = onDuplicateEndpoint
        self.onAddEndpoint = onAddEndpoint
        _searchText = State(initialValue: initialSearchText)
        _collapsedSections = State(initialValue: initialCollapsedSections)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !endpoints.isEmpty {
                // Pinned above the list, never inside it. It used to be the list's first row, so it
                // scrolled away exactly when a long list made it useful. The scope selector is the
                // other half of Xcode's filter bar: filtering is more useful when you can also say
                // what you are filtering by.
                DSFilterField(
                    text: $searchText,
                    scopeID: $methodScopeID,
                    scopes: Self.methodScopes,
                    placeholder: "Filter endpoints",
                    identifier: "sidebar.filter"
                )
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.sm)
            }

            if endpoints.isEmpty {
                DSEmptyState(
                    systemImage: NavigatorTab.endpoints.systemImage,
                    heading: "No endpoints",
                    // Names what the Import menu actually offers. "A Charles export" named a
                    // third-party tool the app mentions nowhere else, and left the reader to work out
                    // that Charles writes HAR — while the menu two panels away says "HAR file".
                    message: "Add an endpoint to define a mock route, or import a HAR file or an "
                        + "OpenAPI spec.",
                    actionTitle: "Add endpoint",
                    identifier: "sidebar.endpoints",
                    action: onAddEndpoint
                )
            } else {
                endpointList
            }
        }
        .navigationTitle(projectName ?? "Mimic")
        .frame(minWidth: 240)
        .onAppear { updateSections() }
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
            // Gated on the *result*, not on the query. Filtering by method scope alone — pick DELETE
            // in a project with no DELETE routes — empties both arrays while `searchText` is still
            // "", so the old condition fell through to the `else` and rendered a list with nothing
            // in it: no heading, no explanation, just a blank panel that reads as a broken app.
            if groupedSections.isEmpty && ungroupedEndpoints.isEmpty {
                Section {
                    Text(noMatchesMessage)
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityIdentifier("sidebar.noMatches")
                }
            } else {
                ForEach(groupedSections, id: \.name) { section in
                    Section(isExpanded: sectionBinding(for: section.name)) {
                        ForEach(section.endpoints) { endpoint in
                            EndpointSidebarRow(endpoint: endpoint)
                                .tag(endpoint.id)
                                .badge("")
                                .contextMenu { endpointContextMenu(endpoint) }
                        }
                    } header: {
                        HStack(spacing: DSSpacing.xs) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(DSColors.labelTertiary)
                            Text(section.name)
                                .font(DSTypography.label)
                                .foregroundStyle(DSColors.labelSecondary)
                            Spacer()
                            Text("\(section.endpoints.count)")
                                .font(DSTypography.caption)
                                // The only number a group header gives you. At 36% a column of them
                                // reads as a smudge down the trailing edge — the same correction the
                                // journeys navigator's step count already carries.
                                .foregroundStyle(DSColors.labelSecondary)
                                // No capsule. `tertiary` on the sidebar's own surface measures about
                                // 1.07:1 — an invisible pill wrapped around the number, costing 8pt
                                // of width to draw nothing. Xcode sets its navigator group counts as
                                // plain secondary text, which is what this is now.
                        }
                        .accessibilityIdentifier("sidebar.group.\(section.name)")
                    }
                }

                if !ungroupedEndpoints.isEmpty {
                    if groupedSections.isEmpty {
                        ForEach(ungroupedEndpoints) { endpoint in
                            EndpointSidebarRow(endpoint: endpoint)
                                .tag(endpoint.id)
                                .badge("")
                                .contextMenu { endpointContextMenu(endpoint) }
                        }
                    } else {
                        Section("Ungrouped") {
                            ForEach(ungroupedEndpoints) { endpoint in
                                EndpointSidebarRow(endpoint: endpoint)
                                    .tag(endpoint.id)
                                    .badge("")
                                    .contextMenu { endpointContextMenu(endpoint) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func endpointContextMenu(_ endpoint: Endpoint) -> some View {
        Button {
            selectedEndpointID = Self.performDuplicate(endpointID: endpoint.id, onDuplicate: onDuplicateEndpoint)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = Self.deleteTarget(for: endpoint)
        } label: {
            Label("Delete endpoint\u{2026}", systemImage: "trash")
        }
    }

    private func sectionBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(name) },
            set: { isExpanded in
                collapsedSections = Self.updatedCollapsedSections(collapsedSections, name: name, isExpanded: isExpanded)
            }
        )
    }

    // MARK: - Data

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
    nonisolated static let anyMethodScopeID = "any"

    /// Scope options for the filter bar. Only the methods an endpoint can actually be, plus "Any".
    static var methodScopes: [DSFilterField.Scope] {
        [DSFilterField.Scope(id: anyMethodScopeID, title: "Any")]
            + [HTTPMethod.get, .post, .put, .patch, .delete].map {
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

        let sections = grouped.keys.sorted().map { groupName in
            SidebarView.EndpointGroup(name: groupName, endpoints: grouped[groupName] ?? [])
        }
        let ungrouped = filteredEndpoints.filter {
            guard let groupTag = $0.groupTag else { return true }
            return groupTag.isEmpty
        }

        return (sections, ungrouped)
    }
}

/// Sidebar row — inline method badge + path, single line.
struct EndpointSidebarRow: View {
    let endpoint: Endpoint

    /// The endpoint's name, when it adds something the path above it has not already said.
    ///
    /// Names created from a logged request read "POST /api/orders", and the sidebar's own creation
    /// flow suggests the same shape — so for most rows the name is the line above it with a method
    /// glued on. Printing that twice is noise; printing a name someone actually chose is not.
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

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            DSMethodBadge(method: endpoint.method.rawValue, size: .compact, identifier: endpoint.id.uuidString)
                .frame(width: 58)

            // One line, with the secondary fact trailing — Xcode's shape, and measured against it.
            // Stacking the name under the path doubled the row to 34pt against Xcode's 17, halving
            // how many endpoints fit. A trailing column costs nothing vertically and yields first
            // when a path is long, which is exactly what Xcode's own status column does.
            //
            // The name has to be *somewhere*, though: a realistic project has two endpoints on
            // `/api/v2/orders` and two on `/api/v2/orders/{id}`, so without it half the rows differ
            // only by their method badge.
            Text(endpoint.path)
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                // The path outranks the name, stated on the path rather than as a negative priority
                // on the name — see the note there.
                .layoutPriority(1)

            if let operation = endpoint.graphqlOperation, !operation.isEmpty {
                // Every GraphQL mock shares one path; without the operation the sidebar would be a
                // column of identical rows, so this one never yields.
                Text(operation)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.accentText)
                    .lineLimit(1)
            } else if let name = Self.subtitle(for: endpoint) {
                Spacer(minLength: DSSpacing.sm)

                Text(name)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Yields before the path does — but *not* via `.layoutPriority(-1)`, which was
                    // here and does not do that. The `Spacer` above sits at default priority, so it
                    // claims the slack first and the name is proposed nothing: it disappeared
                    // instead of truncating, in the rows the comment above says need it most. The
                    // path carries `.layoutPriority(1)` instead, and this cap keeps a long name from
                    // crowding it.
                    .frame(maxWidth: 120, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("endpoint-\(endpoint.id.uuidString)")
    }
}
