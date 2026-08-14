import AppKit
import SwiftUI
import Domain
import DesignSystem

// MARK: - Column & Sort Constants

private enum LogColumns {
    static let method: CGFloat = 62
    static let endpoint: CGFloat = 110
    static let scenario: CGFloat = 90
    static let status: CGFloat = 52
    static let time: CGFloat = 58
    // path is flexible — takes remaining space
}

enum SortField: String {
    case method, path, endpoint, scenario, status, timestamp
}

// MARK: - Header Control Geometry

/// The one shape every control in this panel's header wears.
///
/// The row used to carry four controls in three shapes at three heights, because each was written on
/// its own: a system popup, a bordered pill, a filled well and a bare icon. Xcode's equivalent bars
/// run a single control idiom end to end, and the only way to keep that true here past the next edit
/// is to have the numbers live in one place rather than be matched by hand.
///
/// The numbers are read from the design system rather than restated here. This enum used to hold
/// four literals and a comment promising they matched `DSFilterField` — a coupling across a module
/// boundary, asserted in prose and verified by nobody. `DSControlHeight` and `DSStroke` are where
/// that promise now lives, so adopting the component later cannot change this row's shape.
private enum HeaderControl {
    static let verticalPadding = DSControlHeight.verticalPadding
    static let height = DSControlHeight.row
    static let cornerRadius = DSCornerRadius.sm
    static let borderWidth = DSStroke.hairline
}

private extension View {
    /// Wraps a header control in the panel's shared well: same height, radius, hairline and padding
    /// as every sibling, so the row reads as one set of controls instead of four strangers.
    ///
    /// `fill` and `stroke` are the only things a caller gets to vary, because they are the only
    /// things that carry state — the unmatched filter goes amber when it is on. Geometry is not
    /// negotiable.
    func headerControlWell(
        fill: Color,
        stroke: Color,
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil
    ) -> some View {
        padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, HeaderControl.verticalPadding)
            .frame(minWidth: minWidth, idealWidth: idealWidth)
            .frame(height: HeaderControl.height)
            .background {
                RoundedRectangle(cornerRadius: HeaderControl.cornerRadius)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: HeaderControl.cornerRadius)
                    .stroke(stroke, lineWidth: HeaderControl.borderWidth)
            }
    }
}

enum RequestLogQuery {
    nonisolated static func process(
        logs: [RequestLog],
        endpoints: [Endpoint],
        methodFilter: HTTPMethod?,
        filterText: String,
        unmatchedOnly: Bool = false,
        sortField: SortField,
        sortAscending: Bool
    ) -> [RequestLog] {
        var filteredLogs = logs

        // "Show me only the calls I have not mocked" — the fastest way to find a missing
        // configuration, and the reason this filter is a toggle rather than a search term.
        if unmatchedOnly {
            filteredLogs = filteredLogs.filter(\.outcome.isMissingConfiguration)
        }

        if let methodFilter {
            filteredLogs = filteredLogs.filter { $0.method == methodFilter }
        }

        if !filterText.isEmpty {
            let query = filterText.lowercased()
            filteredLogs = filteredLogs.filter { log in
                log.path.lowercased().contains(query)
                    || "\(log.responseStatusCode ?? 0)".contains(query)
                    || log.outcome.label.lowercased().contains(query)
            }
        }

        // Descending is the ascending predicate with its **operands** swapped, never its answer
        // negated. This used to end on `sortAscending ? result : !result`, and `!(a < b)` is `a >= b`:
        // for two rows whose keys are equal it answered *true* in both directions, so the comparator
        // simultaneously claimed left precedes right and right precedes left. `sort(by:)` requires a
        // strict weak ordering and promises nothing about its output when it does not get one — the
        // result was not "the ascending one reversed", it was whatever the sort's internals happened
        // to do with a contradiction. Ties are not the exotic case here either: a session repeats
        // methods, paths, status codes, endpoint names and scenario names constantly, and the
        // timestamp is the only column of the six that does not normally hold duplicates at all.
        filteredLogs.sort { left, right in
            sortAscending
                ? isOrderedBefore(left, right, sortField: sortField, endpoints: endpoints)
                : isOrderedBefore(right, left, sortField: sortField, endpoints: endpoints)
        }

        return filteredLogs
    }

    /// Whether `left` belongs before `right` with the column sorted ascending.
    ///
    /// One direction only, on purpose: the other is this with the operands swapped — see the note at
    /// the call site for what negating the answer instead did to equal rows.
    ///
    /// Rows whose sorted column is equal fall through to the timestamp. That secondary key is what
    /// makes the order *fully specified* rather than merely legal: `sort(by:)` is not documented as
    /// stable, so on a column with duplicates two equal rows are otherwise free to swap places on
    /// every re-sort, and the log would redraw in a different order after an unrelated filter
    /// keystroke. It reverses along with everything else, so descending puts the newest of a set of
    /// equals first. Two entries carrying the same timestamp *and* the same key compare equal in both
    /// directions, which is precisely what a strict weak ordering asks for.
    nonisolated static func isOrderedBefore(
        _ left: RequestLog,
        _ right: RequestLog,
        sortField: SortField,
        endpoints: [Endpoint]
    ) -> Bool {
        switch sortField {
        case .method:
            if left.method.rawValue != right.method.rawValue {
                return left.method.rawValue < right.method.rawValue
            }
        case .path:
            if left.path != right.path {
                return left.path < right.path
            }
        case .endpoint:
            let leftName = endpointName(for: left.matchedEndpointID, endpoints: endpoints) ?? ""
            let rightName = endpointName(for: right.matchedEndpointID, endpoints: endpoints) ?? ""
            if leftName != rightName { return leftName < rightName }
        case .scenario:
            let leftName = scenarioName(
                endpointID: left.matchedEndpointID,
                scenarioID: left.matchedScenarioID,
                endpoints: endpoints
            ) ?? ""
            let rightName = scenarioName(
                endpointID: right.matchedEndpointID,
                scenarioID: right.matchedScenarioID,
                endpoints: endpoints
            ) ?? ""
            if leftName != rightName { return leftName < rightName }
        case .status:
            let leftCode = left.responseStatusCode ?? 0
            let rightCode = right.responseStatusCode ?? 0
            if leftCode != rightCode { return leftCode < rightCode }
        case .timestamp:
            break
        }

        return left.timestamp < right.timestamp
    }

    /// The path to mock for a logged request: the query string is dropped, because it is a property
    /// of the call and not of the route.
    nonisolated static func mockablePath(from path: String) -> String {
        // `split` omits empty subsequences, so a query-only path such as "?a=1" would otherwise come
        // back as "a=1" — not a route at all. Cut at the separator instead.
        let withoutQuery = path.firstIndex(of: "?").map { String(path[path.startIndex..<$0]) } ?? path
        return withoutQuery.hasPrefix("/") ? withoutQuery : "/"
    }

    /// How many logged requests had nothing configured for them.
    nonisolated static func unmatchedCount(logs: [RequestLog]) -> Int {
        logs.count { $0.outcome.isMissingConfiguration }
    }

    nonisolated static func endpointName(for endpointID: UUID?, endpoints: [Endpoint]) -> String? {
        guard let endpointID else { return nil }
        return endpoints.first { $0.id == endpointID }?.name
    }

    nonisolated static func scenarioName(endpointID: UUID?, scenarioID: UUID?, endpoints: [Endpoint]) -> String? {
        guard let endpointID, let scenarioID else { return nil }
        guard let endpoint = endpoints.first(where: { $0.id == endpointID }) else { return nil }
        return endpoint.scenarios.first { $0.id == scenarioID }?.name
    }

    nonisolated static func formattedDetails(for log: RequestLog) -> String {
        var text = "\(log.method.rawValue) \(log.path)\n"
        if let code = log.responseStatusCode {
            text += "Status: \(code)\n"
        }
        if !log.requestHeaders.isEmpty {
            text += "\nHeaders:\n"
            for (key, value) in log.requestHeaders.sorted(by: { $0.key < $1.key }) {
                text += "  \(key): \(value)\n"
            }
        }
        if let body = log.requestBody, !body.isEmpty {
            text += "\nBody:\n\(body)\n"
        }

        // The response belongs in a copied report: pasting a request into an issue without what came
        // back makes the report half a story.
        text += "\n--- Response (\(log.outcome.label)) ---\n"
        if let failureLabel = log.failureLabel {
            text += "Connection \(failureLabel)\n"
        }
        if !log.responseHeaders.isEmpty {
            text += "\nHeaders:\n"
            for (key, value) in log.responseHeaders.sorted(by: { $0.key < $1.key }) {
                text += "  \(key): \(value)\n"
            }
        }
        if let body = log.responseBody, !body.isEmpty {
            text += "\nBody:\n\(body)\n"
            if log.responseBodyTruncated {
                text += "(truncated at \(RequestLog.maxLoggedBodyBytes / 1024) KB)\n"
            }
        }
        return text
    }
}

// MARK: - Public View

/// The live traffic list: a column table of everything the server has answered.
///
/// Deliberately *only* a list. It used to split itself when you selected a row, showing the request
/// and response in the bottom 45% of a 220pt drawer — which left about 11pt of readable body and cost
/// the list more than half its rows at the moment you most wanted context. Detail now goes to the
/// inspector, which has the height for it, and selection here changes nothing about this panel's
/// layout.
struct RequestLogDrawerView: View {
    let requestLogs: [RequestLog]
    let endpoints: [Endpoint]
    let onClear: () -> Void
    /// The selected rows. Owned by `WorkspaceView` because the inspector needs to see them too — this
    /// panel no longer renders the detail itself.
    ///
    /// A set rather than one id because a selection is also how a journey gets captured: ⌘-click to
    /// pick calls out of a session, ⇧-click to take a stretch of it, then save the lot as a flow.
    /// The inspector shows detail only when exactly one row is selected.
    @Binding var selectedLogIDs: Set<UUID>
    /// Whether the list is restricted to requests nothing answered. Owned outside this panel so the
    /// toolbar's unmatched badge can switch it on, the way Xcode's warning count jumps you to the
    /// issue navigator rather than just telling you a number.
    @Binding var unmatchedOnly: Bool
    /// Creates a mock for a request that matched nothing. Optional so the drawer stays usable in
    /// previews and tests that do not care about it.
    var onCreateEndpoint: ((HTTPMethod, String) -> Void)?
    /// Journeys the selected requests can be appended to.
    var journeys: [Journey] = []
    /// Appends the requests to an existing journey, copying the responses they received.
    var onAddToJourney: (([RequestLog], UUID) -> Void)?
    /// Seeds a new journey with the requests.
    var onAddToNewJourney: (([RequestLog]) -> Void)?

    @State private var filterText = ""
    @State private var methodFilter: HTTPMethod?
    @State private var sortField: SortField = .timestamp
    @State private var sortAscending = false
    @State private var sortedAndFilteredLogs: [RequestLog] = []
    @State private var filterDebounceTask: Task<Void, Never>?
    /// Where a ⇧-click measures its range from: the last row clicked without ⇧. Held here rather than
    /// derived from the selection, because a set has no notion of which end the user started at.
    @State private var selectionAnchorID: UUID?

    public init(
        requestLogs: [RequestLog],
        endpoints: [Endpoint],
        onClear: @escaping () -> Void,
        selectedLogIDs: Binding<Set<UUID>> = .constant([]),
        unmatchedOnly: Binding<Bool> = .constant(false),
        onCreateEndpoint: ((HTTPMethod, String) -> Void)? = nil,
        journeys: [Journey] = [],
        onAddToJourney: (([RequestLog], UUID) -> Void)? = nil,
        onAddToNewJourney: (([RequestLog]) -> Void)? = nil
    ) {
        self.init(
            requestLogs: requestLogs,
            endpoints: endpoints,
            onClear: onClear,
            selectedLogIDs: selectedLogIDs,
            unmatchedOnly: unmatchedOnly,
            onCreateEndpoint: onCreateEndpoint,
            journeys: journeys,
            onAddToJourney: onAddToJourney,
            onAddToNewJourney: onAddToNewJourney,
            initialFilterText: "",
            initialMethodFilter: nil,
            initialSortField: .timestamp,
            initialSortAscending: false
        )
    }

    init(
        requestLogs: [RequestLog],
        endpoints: [Endpoint],
        onClear: @escaping () -> Void,
        selectedLogIDs: Binding<Set<UUID>> = .constant([]),
        unmatchedOnly: Binding<Bool> = .constant(false),
        onCreateEndpoint: ((HTTPMethod, String) -> Void)? = nil,
        journeys: [Journey] = [],
        onAddToJourney: (([RequestLog], UUID) -> Void)? = nil,
        onAddToNewJourney: (([RequestLog]) -> Void)? = nil,
        initialFilterText: String,
        initialMethodFilter: HTTPMethod?,
        initialSortField: SortField,
        initialSortAscending: Bool
    ) {
        self.requestLogs = requestLogs
        self.endpoints = endpoints
        self.onClear = onClear
        _selectedLogIDs = selectedLogIDs
        _unmatchedOnly = unmatchedOnly
        self.onCreateEndpoint = onCreateEndpoint
        self.journeys = journeys
        self.onAddToJourney = onAddToJourney
        self.onAddToNewJourney = onAddToNewJourney
        _filterText = State(initialValue: initialFilterText)
        _methodFilter = State(initialValue: initialMethodFilter)
        _sortField = State(initialValue: initialSortField)
        _sortAscending = State(initialValue: initialSortAscending)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Zone 1: the panel's single row of chrome. `DSPanelHeader` draws its own hairline, so
            // there is no separate divider here — two would read as a double rule.
            drawerToolbar

            // Zone 2 & 3: Content
            if requestLogs.isEmpty {
                DSEmptyState(
                    systemImage: "arrow.down.circle",
                    heading: "No requests yet",
                    message: "Start the server and send a request to see it appear here.",
                    identifier: "drawer.requests"
                )
            } else if sortedAndFilteredLogs.isEmpty {
                DSEmptyState(
                    heading: "No matching requests",
                    message: "Adjust the filter to see results.",
                    identifier: "drawer.noMatches"
                )
            } else {
                // Table header
                tableHeader

                DSDivider(style: .standard, identifier: "drawer.table.header")

                // The list gets the whole panel, selected row or not. Detail lives in the inspector.
                tableBody
            }
        }
        .onChange(of: filterText) { _, _ in updateLogs(debounce: true) }
        .onChange(of: methodFilter) { _, _ in updateLogs() }
        .onChange(of: unmatchedOnly) { _, _ in updateLogs() }
        .onChange(of: sortField) { _, _ in updateLogs() }
        .onChange(of: sortAscending) { _, _ in updateLogs() }
        // The newest entry's identity, not the count. `MockServerRuntime` caps the buffer at 1000 and
        // `removeFirst`s to hold it there, so from request 1001 the count is *permanently* 1000: the
        // panel stops updating and keeps rendering the snapshot it had when the buffer filled, while
        // the real log rotates underneath it. Watching the last id keeps the check O(1) — comparing
        // the whole array would run `Equatable` over 1000 rows on every append.
        .onChange(of: requestLogs.last?.id) { _, _ in updateLogs() }
        .onChange(of: endpoints) { _, _ in updateLogs() }
        .onAppear { updateLogs() }
    }

    // MARK: - Toolbar

    /// The drawer's single row of chrome.
    ///
    /// This used to be two stacked rows — a title with the filters, then the column headers — which
    /// on a 220pt drawer spent roughly a quarter of the panel before showing one request. Now the
    /// count rides in the header's subtitle slot and the filters sit as trailing controls, so the
    /// same information costs one row instead of two.
    @ViewBuilder
    private var drawerToolbar: some View {
        DSPanelHeader("Request log", subtitle: countSubtitle, identifier: "requestLog") {
            HStack(spacing: DSSpacing.sm) {
                if !requestLogs.isEmpty {
                    Picker("Method", selection: $methodFilter) {
                        Text("All").tag(HTTPMethod?.none)
                        ForEach([HTTPMethod.get, .post, .put, .patch, .delete], id: \.self) { method in
                            Text(method.rawValue).tag(HTTPMethod?.some(method))
                        }
                    }
                    // A native popup is the right control for a menu of choices, so this one keeps
                    // the system's shape rather than being dressed as a well. What it does not keep
                    // is a hard-coded width: 72pt was sized for "DELETE" and left the row looking
                    // broken at "All", which is the value it shows almost all the time.
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityIdentifier("drawer.methodFilter")
                    .accessibilityLabel("Filter by method")

                    UnmatchedFilterToggle(
                        count: RequestLogQuery.unmatchedCount(logs: requestLogs),
                        unmatchedOnly: $unmatchedOnly
                    )

                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: DSGlyph.inline, weight: .medium))
                            .foregroundStyle(DSColors.labelTertiary)
                        TextField("Filter", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(DSTypography.codeSmall)
                            .accessibilityIdentifier("drawer.filterField")
                            .accessibilityLabel("Filter request log")
                    }
                    // Range rather than a fixed 150pt: a filter field is the one control in this row
                    // whose useful width depends on the window, and 150 was simultaneously too wide
                    // for a narrow drawer and too narrow to read a path in a wide one.
                    .headerControlWell(
                        fill: DSColors.tertiary,
                        stroke: DSColors.border,
                        minWidth: 120,
                        idealWidth: 160
                    )

                    DSPanelHeaderButton(
                        systemImage: "trash",
                        help: "Clear request log",
                        identifier: "clearRequestLogButton"
                    ) {
                        selectedLogIDs = Self.performClear(onClear: onClear)
                        selectionAnchorID = nil
                    }
                }
            }
        }
    }

    /// The request count, or `nil` when there is nothing to count — an empty panel does not need a
    /// "0 requests" label to tell you it is empty.
    private var countSubtitle: String? {
        guard !requestLogs.isEmpty else { return nil }
        let count = sortedAndFilteredLogs.count
        return "\(count) request\(count == 1 ? "" : "s")"
    }

    // MARK: - Table Header

    @ViewBuilder
    private var tableHeader: some View {
        HStack(spacing: 0) {
            columnHeader("Method", field: .method, width: LogColumns.method)
            columnHeader("Path", field: .path, width: nil)
            columnHeader("Endpoint", field: .endpoint, width: LogColumns.endpoint)
            columnHeader("Scenario", field: .scenario, width: LogColumns.scenario)
            columnHeader("Status", field: .status, width: LogColumns.status)
            columnHeader("Time", field: .timestamp, width: LogColumns.time)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: DSBarHeight.columnHeader)
        // `band`, not `secondary.opacity(0.6)`. The drawer's own surface *is* `secondary`, so 60% of
        // it over itself is exactly itself: this strip was already the same colour as the panel header
        // above it, and the opacity implied a decision nobody had made. The band puts it one step off
        // the drawer, which is the difference between "this row names the panel" and "this row names
        // the columns".
        .background(DSColors.band)
    }

    @ViewBuilder
    private func columnHeader(_ title: String, field: SortField, width: CGFloat?) -> some View {
        SortableColumnHeader(
            title: title,
            isActive: sortField == field,
            isAscending: sortAscending,
            width: width,
            // Keyed on the sort field rather than the title, so the name a test holds does not move
            // when a column is relabelled — the same reason the rows below are keyed on `log.id`.
            identifier: "drawer.columnHeader.\(field.rawValue)"
        ) {
            (sortField, sortAscending) = Self.nextSortState(
                currentField: sortField,
                currentAscending: sortAscending,
                requestedField: field
            )
        }
    }

    // MARK: - Table Body

    @ViewBuilder
    private var tableBody: some View {
        // Both resolved once for the whole table. A row's context menu has to know the entire
        // selection, and working that out inside the row would be O(rows²) on a log that holds a
        // thousand of them.
        let selection = Self.selectedLogs(
            selectedLogIDs: selectedLogIDs,
            sortedAndFilteredLogs: sortedAndFilteredLogs
        )
        let displayOrder = sortedAndFilteredLogs.map(\.id)

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(sortedAndFilteredLogs.enumerated()), id: \.element.id) { index, log in
                    RequestLogTableRow(
                        log: log,
                        rowIndex: index,
                        isSelected: selectedLogIDs.contains(log.id),
                        onCreateEndpoint: onCreateEndpoint,
                        journeys: journeys,
                        selection: selection,
                        onAddToJourney: onAddToJourney,
                        onAddToNewJourney: onAddToNewJourney,
                        endpointName: resolveEndpointName(log.matchedEndpointID),
                        scenarioName: resolveScenarioName(endpointID: log.matchedEndpointID, scenarioID: log.matchedScenarioID),
                        onSelect: { modifier in
                            withAnimation(.easeOut(duration: DSAnimation.fast)) {
                                let change = Self.nextSelection(
                                    current: selectedLogIDs,
                                    anchor: selectionAnchorID,
                                    tapped: log.id,
                                    modifier: modifier,
                                    displayOrder: displayOrder
                                )
                                selectedLogIDs = change.selection
                                selectionAnchorID = change.anchor
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Sorting & Filtering

    private func updateLogs(debounce: Bool = false) {
        filterDebounceTask?.cancel()
        
        let currentLogs = requestLogs
        let currentEndpoints = endpoints
        let currentMethod = methodFilter
        let currentText = filterText
        let currentUnmatchedOnly = unmatchedOnly
        let currentField = sortField
        let currentAsc = sortAscending

        filterDebounceTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            if Task.isCancelled { return }
            
            let result = await Task.detached {
                RequestLogQuery.process(
                    logs: currentLogs,
                    endpoints: currentEndpoints,
                    methodFilter: currentMethod,
                    filterText: currentText,
                    unmatchedOnly: currentUnmatchedOnly,
                    sortField: currentField,
                    sortAscending: currentAsc
                )
            }.value
            
            if !Task.isCancelled {
                self.sortedAndFilteredLogs = result
            }
        }
    }

    // MARK: - Name Resolution

    private func resolveEndpointName(_ endpointID: UUID?) -> String? {
        RequestLogQuery.endpointName(for: endpointID, endpoints: endpoints)
    }

    private func resolveScenarioName(endpointID: UUID?, scenarioID: UUID?) -> String? {
        RequestLogQuery.scenarioName(endpointID: endpointID, scenarioID: scenarioID, endpoints: endpoints)
    }

    /// The selected rows, in the order the table is currently drawing them.
    ///
    /// Display order, not chronological: what the user sees is what they picked. Turning a selection
    /// into journey steps re-sorts it by timestamp, because *that* is where order carries meaning —
    /// see `JourneyStepSpec.capturing(_:)`.
    static func selectedLogs(selectedLogIDs: Set<UUID>, sortedAndFilteredLogs: [RequestLog]) -> [RequestLog] {
        sortedAndFilteredLogs.filter { selectedLogIDs.contains($0.id) }
    }

    /// Which modifier a click carried, and so what it means for the selection.
    enum SelectionModifier: Equatable {
        /// Replace the selection with this row.
        case replace
        /// ⌘: add or remove this row, leaving the rest alone.
        case toggle
        /// ⇧: take everything between the anchor and this row.
        case extend

        init(_ flags: EventModifiers) {
            // ⌘ wins when both are held, matching AppKit: ⌘⇧-click on a table extends by toggling
            // rather than replacing, and picking the destructive reading of an ambiguous chord is
            // how a careful selection gets thrown away.
            if flags.contains(.command) {
                self = .toggle
            } else if flags.contains(.shift) {
                self = .extend
            } else {
                self = .replace
            }
        }

        /// The modifier held as the click is handled.
        ///
        /// SwiftUI's tap gestures do not report modifier keys, so matching them means attaching a
        /// separate `TapGesture().modifiers(_:)` per chord — and those compose unreliably against the
        /// plain tap, often enough that ⇧-click feels broken rather than unimplemented. Reading the
        /// flags once, at click time, is a single code path.
        ///
        /// The click's **own** flags come first, with the keyboard's live state as the fallback. The
        /// two agree for a person at the machine and come apart for anything synthesising input:
        ///
        /// - XCUITest's `perform(withKeyModifiers:)` moves device state, so `NSEvent.modifierFlags`
        ///   alone is enough for the UI suite to pass.
        /// - A posted `CGEvent` carries its modifiers on the event and leaves device state untouched,
        ///   so `NSEvent.modifierFlags` alone reports *no* modifier and a ⌘-click silently collapses
        ///   the selection to one row. Observed while driving this window through the computer-use
        ///   layer, which is the same shape as an agent automating the app — and this app is meant to
        ///   be drivable that way.
        ///
        /// Reading the event first covers both; the device state still answers when no event is in
        /// flight.
        @MainActor
        static var current: Self {
            let flags = NSApplication.shared.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            var modifiers: EventModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            return Self(modifiers)
        }
    }

    /// The selection and anchor a click produces.
    struct SelectionChange: Equatable {
        var selection: Set<UUID>
        var anchor: UUID?
    }

    /// How a click changes the selection.
    ///
    /// Pure and static because modifier handling is exactly the kind of logic that looks obviously
    /// right and is wrong at the edges — ⇧-click with no anchor yet, ⌘-click that removes the anchor
    /// itself, a range whose ends arrive in either order.
    static func nextSelection(
        current: Set<UUID>,
        anchor: UUID?,
        tapped: UUID,
        modifier: SelectionModifier,
        displayOrder: [UUID]
    ) -> SelectionChange {
        switch modifier {
        case .replace:
            // Clicking the only selected row clears it. That is how this panel has always behaved,
            // and it is how the inspector's request detail gets dismissed without hunting for the
            // close button.
            if current == [tapped] {
                return SelectionChange(selection: [], anchor: nil)
            }
            return SelectionChange(selection: [tapped], anchor: tapped)

        case .toggle:
            var next = current
            guard next.remove(tapped) != nil else {
                next.insert(tapped)
                return SelectionChange(selection: next, anchor: tapped)
            }
            // Deselecting the anchor leaves a range with nothing to measure from, so the next
            // ⇧-click should start from a row that is actually still selected.
            return SelectionChange(
                selection: next,
                anchor: anchor == tapped ? displayOrder.last(where: next.contains) : anchor
            )

        case .extend:
            // An anchor that is no longer selected is stale, because the selection can be set from
            // outside this table — picking a request from an endpoint's traffic list does exactly
            // that, and leaves the anchor pointing at whatever was clicked here last. Falling back to
            // the last row that *is* selected keeps the range measured from something on screen.
            let anchor = anchor.flatMap { current.contains($0) ? $0 : nil }
                ?? displayOrder.last(where: current.contains)
            guard let anchor,
                  let start = displayOrder.firstIndex(of: anchor),
                  let end = displayOrder.firstIndex(of: tapped)
            else {
                // Nothing to extend from. AppKit treats this as a plain click rather than ignoring
                // it, and a control that does nothing on first use reads as broken.
                return SelectionChange(selection: [tapped], anchor: tapped)
            }
            // Unions rather than replaces, so ⌘-picking a few calls and then ⇧-taking a run adds to
            // the selection instead of discarding the careful part of it. The anchor stays put, so
            // dragging the range back and forth keeps measuring from the same end.
            return SelectionChange(
                selection: current.union(displayOrder[min(start, end)...max(start, end)]),
                anchor: anchor
            )
        }
    }

    static func performClear(onClear: () -> Void) -> Set<UUID> {
        onClear()
        return []
    }

    static func nextSortState(
        currentField: SortField,
        currentAscending: Bool,
        requestedField: SortField
    ) -> (field: SortField, isAscending: Bool) {
        if currentField == requestedField {
            return (requestedField, !currentAscending)
        }
        return (requestedField, requestedField != .timestamp)
    }
}

// MARK: - Unmatched filter

/// A one-click answer to "what is my app calling that I have not mocked?".
///
/// The count is on the control itself, so a missing mock is visible without opening the filter —
/// which is the whole point: you notice it while debugging something else.
///
/// Its own view so the hover state stays local, which is the same reason `SortableColumnHeader`
/// below is one: held on the drawer, a `@State` flag toggled by the pointer crossing this control
/// would re-evaluate the panel's whole body — the table of up to a thousand rows included — twice per
/// pass of the mouse.
private struct UnmatchedFilterToggle: View {
    let count: Int
    @Binding var unmatchedOnly: Bool

    @State private var isHovered = false

    var body: some View {
        // Not a `.toggleStyle(.button)` Toggle. That draws a bordered capsule, and tinting it amber
        // to advertise the count made the control look pressed whenever there was anything to count —
        // so a filter that was off read as on, every time it mattered. On and off have to look
        // different from each other before either can carry a colour.
        Button {
            unmatchedOnly.toggle()
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: DSGlyph.inline))
                Text(count > 0 ? "Unmatched (\(count))" : "Unmatched")
                    .font(DSTypography.caption)
            }
            .foregroundStyle(foreground)
            // The same well as the filter field beside it — one height, one radius, one hairline.
            // These two were written independently and drifted by a couple of points, which is
            // exactly the kind of difference nobody can name and everybody can see.
            .headerControlWell(fill: fill, stroke: stroke)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isInert)
        // This control had no pointer response of any kind, which in a row where the clear button is
        // a `DSPanelHeaderButton` and the method filter is a native popup made it the one thing in
        // the drawer's chrome that looked the same whether or not you were about to click it.
        //
        // Gated on `isInert` for the reason `ServerToggleButton` states: a well that answers a
        // pointer which cannot click is the same lie as a live-looking dead control.
        .onHover { isHovered = $0 && !isInert }
        .animation(.easeOut(duration: DSAnimation.micro), value: unmatchedOnly)
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help("Show only requests that matched no endpoint — the ones you are missing a mock for.")
        .accessibilityIdentifier("drawer.unmatchedFilter")
        .accessibilityLabel(
            count > 0
                ? "Show only unmatched requests, \(count) so far"
                : "Show only unmatched requests"
        )
    }

    /// Nothing to filter to and not already filtering: the control is disabled, so it neither reacts
    /// to the pointer nor carries a colour.
    private var isInert: Bool { count == 0 && !unmatchedOnly }

    /// Amber once the filter is on, or once there is something to find. Quiet otherwise — a control
    /// that is always coloured has stopped saying anything.
    private var foreground: Color {
        if unmatchedOnly || count > 0 { return DSColors.httpStatusColor(for: 404) }
        return DSColors.labelSecondary
    }

    /// On, the well stays amber under the pointer rather than being overpainted by a blue that means
    /// nothing here — the rule `ServerToggleButton`'s running glow follows. Off, it takes
    /// `accentSubtle`, which is the app's one hover fill.
    private var fill: Color {
        if unmatchedOnly { return DSColors.httpStatusColor(for: 404).opacity(0.12) }
        return isHovered ? DSColors.accentSubtle : .clear
    }

    private var stroke: Color {
        unmatchedOnly ? DSColors.httpStatusColor(for: 404) : DSColors.border
    }
}

// MARK: - Column Header

/// One sortable column title.
///
/// Sentence case, like every table header in macOS and every one in Xcode. This row used to shout
/// its titles in caps, which is a web convention borrowed into an AppKit window: it made six labels
/// compete with the traffic underneath them, and traffic is the reason the panel exists.
///
/// Its own view so the hover highlight stays local. Kept on the table as a `hoveredField`, one
/// pointer crossing the row would re-evaluate all six columns — `DSTabStrip.TabButton` is the same
/// shape for the same reason.
///
/// **It is a `Button`, so it is named like one.** All six of these shipped with no accessibility
/// identifier and no label, on the type or at the call site — six interactive controls that VoiceOver
/// could only announce by reading the word inside them, with nothing saying they sorted anything and
/// nothing a UI test could address. The sort direction rides in the value rather than the label, so
/// the label stays a stable string while the state underneath it moves, exactly as `DSTabStrip` does
/// with its badge count.
private struct SortableColumnHeader: View {
    let title: String
    let isActive: Bool
    let isAscending: Bool
    /// `nil` for the flexible column, which takes whatever the fixed ones leave.
    let width: CGFloat?
    let identifier: String
    let sort: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: sort) {
            HStack(spacing: DSSpacing.xxs) {
                Text(title)
                    .font(DSTypography.caption)
                    // The sorted column should be legible as sorted from across the row, without
                    // first finding a chevron to read.
                    .fontWeight(isActive ? .semibold : nil)
                    .foregroundStyle(titleColor)

                if isActive {
                    Image(systemName: isAscending ? "chevron.up" : "chevron.down")
                        // `inlineSmall`, the rung `DSGlyph` names a column header's sort chevron for:
                        // it qualifies the title beside it rather than being the control itself.
                        .font(.system(size: DSGlyph.inlineSmall, weight: .semibold))
                        .foregroundStyle(DSColors.accentText)
                }
            }
            // Inside the label, so the whole cell is the target rather than just the word — a
            // header that only responds where the glyphs happen to be reads as broken, and the
            // hover highlight would flicker on and off as the pointer crossed the gaps.
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing else said these were sortable. A plain button gives no pressed state, no pointer
        // change and no hover, so the columns looked exactly like a static legend.
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help("Sort by \(title.lowercased())")
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Sort by \(title.lowercased())")
        .accessibilityValue(sortStateAnnouncement)
    }

    /// Which way this column is currently sorting, or nothing when it is not the sorted one. A value
    /// rather than part of the label, so "Sort by status" stays the same string whichever direction
    /// the arrow is pointing.
    private var sortStateAnnouncement: String {
        guard isActive else { return "" }
        return isAscending ? "sorted ascending" : "sorted descending"
    }

    private var titleColor: Color {
        if isHovered { return DSColors.labelPrimary }
        // An inactive column header is still a button you are meant to find and press. At 36% the
        // row read as a static legend — which this type's own note says was the bug — and it was the
        // one control class left at that alpha after `DSTabStrip`, `DSPanelHeaderButton` and
        // `ServerToggleButton` were each moved off it.
        return isActive ? DSColors.labelPrimary : DSColors.labelSecondary
    }
}

// MARK: - Table Row

struct RequestLogTableRow: View {
    let log: RequestLog
    let rowIndex: Int
    let isSelected: Bool
    var onCreateEndpoint: ((HTTPMethod, String) -> Void)?
    var journeys: [Journey] = []
    /// Every selected row, in display order, so a right-click on one of them can act on all of them.
    var selection: [RequestLog] = []
    var onAddToJourney: (([RequestLog], UUID) -> Void)?
    var onAddToNewJourney: (([RequestLog]) -> Void)?
    let endpointName: String?
    let scenarioName: String?
    let onSelect: (RequestLogDrawerView.SelectionModifier) -> Void
    @State private var isHovered = false

    /// What a capture acts on: the whole selection when this row belongs to a multi-row one, and
    /// otherwise just this row.
    ///
    /// Right-clicking a row *outside* the selection must not act on the selection — that would be a
    /// menu doing something to rows the pointer is nowhere near, which is how people lose work they
    /// spent a minute picking.
    private var capturable: [RequestLog] {
        selection.count > 1 && selection.contains(where: { $0.id == log.id }) ? selection : [log]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Method
            // Keyed by the log entry, not by the method: every GET row shared one identifier when the
            // badge defaulted to the method name, so a query for it resolved to an arbitrary row.
            DSMethodBadge(method: log.method.rawValue, size: .compact, identifier: log.id.uuidString)
                .frame(width: LogColumns.method, alignment: .leading)

            // Path
            Text(log.path)
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Endpoint — or, when none matched, what did answer. A bare em dash here used to mean
            // both "unconfigured" and "a journey answered", which is exactly the distinction someone
            // debugging a missing mock needs.
            endpointCell
                .frame(width: LogColumns.endpoint, alignment: .leading)
                .accessibilityIdentifier("requestLog.endpointName.\(log.id.uuidString)")

            // Scenario
            Text(scenarioName ?? "\u{2014}")
                .font(DSTypography.caption)
                .foregroundStyle(scenarioName != nil ? DSColors.accentText : DSColors.labelTertiary)
                .lineLimit(1)
                .frame(width: LogColumns.scenario, alignment: .leading)
                .accessibilityIdentifier("requestLog.scenarioName.\(log.id.uuidString)")

            // Status code pill
            statusPill
                .frame(width: LogColumns.status, alignment: .leading)

            // Time
            Text(log.timestamp, style: .time)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .frame(width: LogColumns.time, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .contextMenu {
            // Going from "this call is unmocked" to "it is mocked now" should not require retyping
            // the method and path into a sheet.
            if log.outcome.isMissingConfiguration, let onCreateEndpoint {
                Button {
                    onCreateEndpoint(log.method, RequestLogQuery.mockablePath(from: log.path))
                } label: {
                    Label(
                        "Create endpoint for \(log.method.rawValue) \(RequestLogQuery.mockablePath(from: log.path))",
                        systemImage: "plus.circle"
                    )
                }
                .accessibilityIdentifier("requestLog.createEndpoint.\(log.id.uuidString)")
            }

            // A request a journey already answered is by definition in one, so offering to add it
            // again would only produce a duplicate step. Filtered rather than refused, because a
            // selection spanning a session is very likely to contain a few of them.
            let targets = capturable.filter { $0.outcome != .journey }
            if !targets.isEmpty, onAddToJourney != nil || onAddToNewJourney != nil {
                Menu(targets.count == 1 ? "Add to journey" : "Add \(targets.count) requests to journey") {
                    ForEach(journeys) { journey in
                        Button(journey.name) {
                            onAddToJourney?(targets, journey.id)
                        }
                        .accessibilityIdentifier("requestLog.addToJourney.\(journey.id.uuidString)")
                    }

                    if !journeys.isEmpty {
                        Divider()
                    }

                    Button(
                        targets.count == 1
                            ? "New journey from this request\u{2026}"
                            : "New journey from these \(targets.count) requests\u{2026}"
                    ) {
                        onAddToNewJourney?(targets)
                    }
                    .accessibilityIdentifier("requestLog.addToNewJourney.\(log.id.uuidString)")
                }
                .accessibilityIdentifier("requestLog.addToJourneyMenu.\(log.id.uuidString)")
            }
        }
        .frame(height: 26)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(DSColors.accent)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(.current) }
        .onHover { isHovered = $0 }
        // One element with one spoken label, exactly as `EndpointTrafficRow` forms itself — this
        // was the only interactive row in the window that composed none: a bare `.isButton` over
        // six loose cells, which VoiceOver read as six fragments ("GET method", "/api/orders",
        // "Unmatched"…) with nothing saying they were one request. The trait comes after the
        // element is formed, because a trait added to the children is a trait the element has
        // already passed over — and the row is a tap target rather than a `Button` in the first
        // place because a button would swallow the modifier chords the selection depends on.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("requestLog-\(log.id.uuidString)")
        .accessibilityLabel(Self.spokenLabel(for: log))
    }

    private var rowBackground: Color {
        if isSelected { return DSColors.accentSubtle }
        if isHovered { return DSColors.accentSubtle.opacity(0.6) }
        return rowIndex % 2 == 0 ? .clear : DSColors.rowStripe
    }

    @ViewBuilder
    private var endpointCell: some View {
        if let endpointName {
            Text(endpointName)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
        } else {
            switch log.outcome {
            case .unmatched:
                Text(RequestOutcome.unmatched.label)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.httpStatusColor(for: 404))
                    .lineLimit(1)
            case .blockedByJourney:
                Text(RequestOutcome.blockedByJourney.label)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
            case .journey:
                Text(RequestOutcome.journey.label)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.accentText)
                    .lineLimit(1)
            case .endpoint:
                // An endpoint answered but has since been renamed or deleted.
                Text("\u{2014}")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
            }
        }
    }

    /// `DSStatusPill` carries the whole convention — the `>= 400` fill gate, the text-variant
    /// colours, and the failure arm. The last one is why this is a component and not a pattern:
    /// this row used to spell a failed request `log.responseStatusCode ?? 0` and drew a bare grey
    /// `0` with no fill — a status no server ever sent, styled as ordinary — while
    /// `EndpointTrafficRow` rendered the same log as a filled destructive em dash. The em dash is
    /// the defended treatment, and the row now inherits it instead of re-deciding it.
    private var statusPill: some View {
        DSStatusPill(statusCode: log.responseStatusCode)
    }

    /// What VoiceOver reads for the row — same composition as `EndpointTrafficRow.spokenLabel`,
    /// which is this row one panel over. `static` so `WorkspaceFeatureTests` can hold the three
    /// arms without hosting a window.
    nonisolated static func spokenLabel(for log: RequestLog) -> String {
        if let code = log.responseStatusCode {
            return "\(log.method.rawValue) \(log.path), status \(code)"
        }
        if let failureLabel = log.failureLabel {
            return "\(log.method.rawValue) \(log.path), failed: \(failureLabel)"
        }
        return "\(log.method.rawValue) \(log.path), no response"
    }
}
