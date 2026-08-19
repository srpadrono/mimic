import AppKit
import SwiftUI
import Domain
import DesignSystem

// MARK: - Column & Sort Constants

/// The log's column widths.
///
/// One flexible column and five fixed ones, which is the structure rather than an accident: the
/// header cells and the row cells read these same numbers, so a width that lived in only one of them
/// would put the two out of step — a defect this file has met before.
///
/// The fixed five were sized before the columns held what they hold now. `endpoint` and `scenario`
/// are names a user chose and are routinely longer than the em dash the empty case draws, while
/// `path` — the only flexible member — took the entire remainder of a wide pane to hold a short
/// route. Widening the cramped columns spends some of that surplus without changing the structure.
/// `path` still takes what is left, and still truncates first, which is right: it is the column a
/// reader scans rather than reads to the end.
enum LogColumns {
    static let method: CGFloat = 62

    /// Up from 110. Holds an endpoint's name, which is prose rather than a token.
    static let endpoint: CGFloat = 130

    /// Up from 90, for the same reason.
    static let scenario: CGFloat = 100

    static let status: CGFloat = 52

    /// Up from 58, which fitted "9:41 AM" and does not fit "9:41:33 AM". Sized for a 12-hour locale,
    /// the wider of the two, at `Figure.small`: "11:41:33 PM" is eleven characters and SF Mono
    /// advances 0.6em, so 11pt needs 72.6 — and 72 was picked by eye before the test measured it.
    static let time: CGFloat = 74

    // path is flexible — takes remaining space
}

/// One traffic row's geometry.
///
/// 26 is `DSControlHeight.denseRow`, a rung of its own rather than one of `row` (20) or `field`
/// (22): neither of those holds a `compact` method badge above a line of `codeSmall`. A dense table
/// row is a fourth thing, and `ImportReviewList`'s candidate row stands on the same rung — through
/// the token now, where the two used to be a pair of literals coupled by a sentence in each file
/// naming the other.
private enum LogRow {
    static let height = DSControlHeight.denseRow
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
    /// Wraps a header control in the panel's shared well: same height, radius and padding as every
    /// sibling, so the row reads as one set of controls instead of four strangers.
    ///
    /// A caller varies the line only where the line carries state — the unmatched filter goes amber
    /// when it is on, and a field being typed into wears `DSStroke.focusRing`, which is a point
    /// heavier than a hairline for exactly that reason (`DSStroke` names the two separately because
    /// one is a boundary and the other is a state). Height, radius and padding are not negotiable.
    func headerControlWell(
        fill: Color,
        stroke: Color,
        strokeWidth: CGFloat = HeaderControl.borderWidth,
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
                    .stroke(stroke, lineWidth: strokeWidth)
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
        // Every predicate here is `RequestLogFilter` in Domain, which `HostReport.requestLog` also
        // calls. The rules used to be written twice — here for the drawer's rows, and again for the
        // `logList` command — so `mimic log list --unmatched` and the drawer's own toggle were two
        // separate answers to one question, agreeing only because nobody had changed either.
        //
        // Sorting stays here. It is not a rule about which requests matter, it is a rule about how a
        // *table* orders itself, and it needs `endpoints` to resolve the "Answered by" column — which
        // is view state, not a property of the log.
        var filteredLogs = RequestLogFilter(
            unmatchedOnly: unmatchedOnly,
            method: methodFilter,
            text: filterText
        ).apply(to: logs)

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
    /// Whether the filter field has the keyboard, so the well can draw a ring around it. Separate
    /// from the table's focus below: the two are different targets and only one of them can be the
    /// one you are typing into.
    @FocusState private var filterFieldIsFocused: Bool
    /// Whether the table holds keyboard focus, which is what the arrow keys, Return, Escape and ⌘A
    /// below are conditional on.
    ///
    /// The table is one focus target rather than one per row, the way an AppKit table is: focus
    /// lands on the list and the keys move within it. A thousand focusable rows would put a
    /// thousand stops in the window's key-view loop.
    @FocusState private var tableHasKeyboardFocus: Bool

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
        // The drawer paints its own surface. It used to paint none, so the panel showed whatever the
        // window happened to be behind it — and its own zebra made that visible, because every even
        // row resolves to `.clear` and was letting the background through rather than sitting on a
        // surface of its own.
        //
        // `dominant`, the same canvas as the editor above it: the two share the centre column and
        // are separated by `DSSplitPane`'s own divider band, not by a change of colour.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColors.dominant)
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
                            .focused($filterFieldIsFocused)
                            .accessibilityIdentifier("drawer.filterField")
                            .accessibilityLabel("Filter request log")
                    }
                    // Range rather than a fixed 150pt: a filter field is the one control in this row
                    // whose useful width depends on the window, and 150 was simultaneously too wide
                    // for a narrow drawer and too narrow to read a path in a wide one.
                    //
                    // The focused line is `DSFilterField`'s exactly — `borderFocused` at
                    // `DSStroke.focusRing` — because `.textFieldStyle(.plain)` throws AppKit's own
                    // ring away, and a control that looks identical whether or not it has the
                    // keyboard is the hover defect applied to Full Keyboard Access. This field is
                    // one of the two hand-rolled ones that component's own note names; it keeps its
                    // shape here rather than adopting the component, because the component is a
                    // capsule with a scope pill and this row is four rectangular wells.
                    .headerControlWell(
                        fill: DSColors.tertiary,
                        stroke: filterFieldIsFocused ? DSColors.borderFocused : DSColors.border,
                        strokeWidth: filterFieldIsFocused ? DSStroke.focusRing : HeaderControl.borderWidth,
                        minWidth: 120,
                        idealWidth: 160
                    )
                    .animation(.easeOut(duration: DSAnimation.fast), value: filterFieldIsFocused)

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

        ScrollViewReader { proxy in
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
                                // The pointer hands the table its focus, so the arrows carry on from
                                // the row that was just clicked rather than from wherever they were
                                // left. `WelcomeWindow`'s recents list keeps the same contract in the
                                // other direction.
                                tableHasKeyboardFocus = true
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
            // Selection here was reachable only by pointer — and this is the app's one multi-select
            // surface, the one a journey is captured from, so capturing a flow was a pointer-only
            // workflow end to end. `.focusable()` is what lets a `ScrollView` of tap targets take a
            // key press at all; a `List` would have brought the arrows with it, and this panel is
            // deliberately not one (six columns at a fixed row height).
            .focusable()
            .focused($tableHasKeyboardFocus)
            // `.repeat` as well as `.down`: macOS delivers a held key as one press and then a run of
            // repeats, so without it holding ↓ moves the selection exactly one row and then stops —
            // which reads as the key having been dropped. `.up` is deliberately absent; taking it
            // would run every press twice.
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape, "a"], phases: [.down, .repeat]) { press in
                handleKeyPress(press, displayOrder: displayOrder, proxy: proxy)
            }
        }
    }

    /// Arrow keys, Return, Escape and ⌘A, while the table holds focus.
    ///
    /// The whole decision is in ``nextSelection(key:extending:current:anchor:displayOrder:)``, which
    /// is pure; this reads the press, writes the two pieces of state and scrolls the row it moved to
    /// into view. A press the table declines comes back `.ignored`, which leaves the event to
    /// whatever is behind it — the scroll view's own paging, in the case of an arrow at the end of
    /// the list.
    private func handleKeyPress(
        _ press: KeyPress,
        displayOrder: [UUID],
        proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard let key = Self.selectionKey(key: press.key, modifiers: press.modifiers),
              let result = Self.nextSelection(
                  key: key,
                  extending: press.modifiers.contains(.shift),
                  current: selectedLogIDs,
                  anchor: selectionAnchorID,
                  displayOrder: displayOrder
              )
        else { return .ignored }

        withAnimation(.easeOut(duration: DSAnimation.fast)) {
            selectedLogIDs = result.change.selection
            selectionAnchorID = result.change.anchor
        }

        // Unanimated on purpose: the row has to be on screen by the time the next key press is
        // handled, and a keyboard user holding ↓ generates them faster than a scroll animation
        // settles.
        if let reveal = result.reveal {
            proxy.scrollTo(reveal)
        }

        return .handled
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

    /// What a key press means for the selection, in the table's own language.
    enum SelectionKey: Equatable {
        /// ↑ — move to the row above the top of the selection.
        case moveUp
        /// ↓ — move to the row below the bottom of it.
        case moveDown
        /// Return — collapse the selection onto one row, which is what shows a request in the
        /// inspector.
        case activate
        /// ⌘A — take every row the filter is currently showing.
        case selectAll
        /// Escape — select nothing.
        case clear
    }

    /// Which key the table handles, or `nil` for one it leaves alone.
    ///
    /// Takes the key and the modifiers rather than the `KeyPress` so the mapping is testable without
    /// a window: `KeyPress` is a value SwiftUI hands out and not one a test can build.
    ///
    /// ⌘A is matched here rather than declared as a menu command because a menu lives on a `Scene`
    /// and this is a panel. AppKit offers an enabled key equivalent its menu item first and only
    /// then the focused view, so the reach of this arm is exactly "no menu item claimed ⌘A" — which
    /// is the state of this app's menu bar. A menu item is what would make it *discoverable*, and
    /// that belongs in `MimicScene` beside the other commands.
    static func selectionKey(key: KeyEquivalent, modifiers: EventModifiers) -> SelectionKey? {
        // Statements rather than a switch *expression* returning an Optional by implicit member.
        // Both spell the same mapping, but nothing else in this repository takes that shape, and a
        // construct with no precedent here is one nobody has watched this toolchain compile — not
        // worth a forty-minute round trip to find out, when the statement form is free.
        switch key {
        case .upArrow: return .moveUp
        case .downArrow: return .moveDown
        case .return: return .activate
        case .escape: return .clear
        case "a" where modifiers.contains(.command): return .selectAll
        default: return nil
        }
    }

    /// The selection a key press produces, and the row the table should reveal with it.
    struct KeyboardSelection: Equatable {
        var change: SelectionChange
        /// The row the press moved to, which the table scrolls into view. `nil` for a press that
        /// changes the selection without moving — ⌘A and Escape — because scrolling on those would
        /// move the list under someone who did not ask it to.
        var reveal: UUID?
    }

    /// How a key press changes the selection.
    ///
    /// `nil` means the table does not act on the press, so the caller can hand the event back rather
    /// than swallowing it: an arrow at the end of the list, Return on a row that is already alone in
    /// the selection, Escape with nothing selected.
    ///
    /// Pure and static for the reason the click path above is: the interesting cases are all at the
    /// edges, and they are cheaper to pin here than to drive through a window.
    ///
    /// **An arrow moves from the edge of the selection it is pushing against** — ↓ from the last
    /// selected row, ↑ from the first — rather than from a separate keyboard cursor. For the single
    /// selection an arrow key usually starts from, the two are the same row. For a multi-row one,
    /// this is what makes ⇧↓ ⇧↓ grow the range a row at a time instead of re-measuring from the
    /// anchor and adding the same row twice. The range only grows: shrinking it is a click or a
    /// ⌘-click, which is where the anchor is set.
    static func nextSelection(
        key: SelectionKey,
        extending: Bool,
        current: Set<UUID>,
        anchor: UUID?,
        displayOrder: [UUID]
    ) -> KeyboardSelection? {
        guard displayOrder.isEmpty == false else { return nil }

        switch key {
        case .selectAll:
            // Membership, not size. A count comparison declines a legitimate press whenever the
            // selection happens to be the same size as what is shown — select two rows, then narrow
            // the filter to two *different* ones, and ⌘A did nothing with nothing to say why.
            guard current != Set(displayOrder) else { return nil }
            return KeyboardSelection(
                change: SelectionChange(selection: Set(displayOrder), anchor: displayOrder.last),
                reveal: nil
            )

        case .clear:
            guard current.isEmpty == false else { return nil }
            return KeyboardSelection(change: SelectionChange(selection: [], anchor: nil), reveal: nil)

        case .activate:
            // Return collapses a multi-row selection onto one row, because the inspector shows a
            // request only when exactly one is selected — so this is the keyboard's "open it".
            // Never the reverse: a row already alone in the selection is open, and clearing it here
            // would make Return a dismiss key on the one press a reader would expect to confirm.
            guard let target = displayOrder.last(where: current.contains), current != [target] else {
                return nil
            }
            return KeyboardSelection(
                change: SelectionChange(selection: [target], anchor: target),
                reveal: target
            )

        case .moveUp, .moveDown:
            let forward = key == .moveDown
            let edge = forward
                ? displayOrder.last(where: current.contains)
                : displayOrder.first(where: current.contains)

            guard let edge, let index = displayOrder.firstIndex(of: edge) else {
                // Nothing selected: an arrow starts at the near end of the list, as an AppKit table
                // does, rather than doing nothing until something has been clicked.
                guard let start = forward ? displayOrder.first : displayOrder.last else { return nil }
                return KeyboardSelection(
                    change: SelectionChange(selection: [start], anchor: start),
                    reveal: start
                )
            }

            let targetIndex = forward ? index + 1 : index - 1
            guard displayOrder.indices.contains(targetIndex) else { return nil }
            let target = displayOrder[targetIndex]

            guard extending else {
                return KeyboardSelection(
                    change: SelectionChange(selection: [target], anchor: target),
                    reveal: target
                )
            }

            // The anchor survives a ⇧-arrow so a run of them measures from one end, and falls back
            // to the edge it just grew from when the selection no longer contains it — the same
            // staleness the ⇧-click arm guards against, and for the same reason: this selection can
            // be set from outside the table.
            var extended = current
            extended.insert(target)
            return KeyboardSelection(
                change: SelectionChange(
                    selection: extended,
                    anchor: anchor.flatMap { extended.contains($0) ? $0 : nil } ?? edge
                ),
                reveal: target
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
            //
            // No per-cell `.accessibilityIdentifier` on this cell or the scenario one: the row
            // composes with `.accessibilityElement(children: .ignore)`, which swallows its children
            // whole, so an identifier down here names an element nothing can ever find. What those
            // two cells say is in `spokenLabel` instead, where a reader can hear it.
            endpointCell
                .frame(width: LogColumns.endpoint, alignment: .leading)

            // Scenario
            Text(scenarioName ?? "\u{2014}")
                .font(DSTypography.caption)
                .foregroundStyle(scenarioName != nil ? DSColors.accentText : DSColors.labelTertiary)
                .lineLimit(1)
                .frame(width: LogColumns.scenario, alignment: .leading)

            // Status code pill
            statusPill
                .frame(width: LogColumns.status, alignment: .leading)

            // Time
            // Seconds, and monospaced digits.
            //
            // `style: .time` is hours and minutes, so a burst of requests — which is what a mock
            // server produces — gave every row the identical "12:38". The one job this column has is
            // letting you match a row against the tap you just made, and without seconds it could
            // not do it. `.dateTime` rather than a `DateFormatter` so the 12/24-hour choice stays the
            // reader's locale rather than this file's opinion.
            //
            // `Figure.small` is `codeSmall.monospacedDigit()`, which exists for exactly this: at a
            // proportional face the colons and the 1s wandered, so a column of times did not line up
            // as a column.
            Text(log.timestamp, format: .dateTime.hour().minute().second())
                .font(DSTypography.Figure.small)
                .foregroundStyle(DSColors.labelTertiary)
                .frame(width: LogColumns.time, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: LogRow.height)
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
        // "Unmatched"…) with nothing saying they were one request. The traits come after the
        // element is formed, because a trait added to the children is a trait the element has
        // already passed over — and the row is a tap target rather than a `Button` in the first
        // place because a button would swallow the modifier chords the selection depends on.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(rowTraits)
        .accessibilityIdentifier("requestLog-\(log.id.uuidString)")
        .accessibilityLabel(
            Self.spokenLabel(
                for: log,
                endpointName: endpointName,
                scenarioName: scenarioName,
                isSelected: isSelected
            )
        )
        // The menu attaches after the element is formed, exactly as the scenario row orders it —
        // and here that ordering is load-bearing, not stylistic. This menu used to sit before the
        // `.accessibilityElement(children: .ignore)` above, which collapses the accessibility of
        // everything beneath it: the menu still opened for a pointer, but its items surfaced
        // through the swallowed subtree and so never existed as elements. VoiceOver lost the menu,
        // and the UI test that opens it read "no menu appeared" — deterministically, on every run,
        // which spent five CI rounds masquerading as a flaky modifier. Attached out here, the open
        // menu's items are ordinary elements again. It also widens the right-click target from the
        // padded content to the full row frame, matching where the row already takes a left click.
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
    }

    /// `.isButton` always, and `.isSelected` while the row is in the selection.
    ///
    /// Both halves of the selection are needed and they answer different questions. The trait is the
    /// programmatic fact — what Accessibility Inspector reads and what an XCUITest can assert — and
    /// the wording in ``spokenLabel(for:endpointName:scenarioName:isSelected:)`` is what is actually
    /// *said*, because this table is a `LazyVStack` of tap targets rather than an AppKit table and
    /// there is no row container above it to announce a selection on the row's behalf.
    ///
    /// It matters more here than anywhere else in the window: this is the app's only multi-select
    /// surface, and the selection is precisely what a capture-to-journey acts on. Without it the
    /// accent stripe down the row's leading edge is the *only* statement that a row is in the set,
    /// which is no statement at all to somebody who is being read the panel.
    var rowTraits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : .isButton
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

    /// What VoiceOver reads for the row: the request, what came back, what answered it, and whether
    /// it is in the selection. `static` so `WorkspaceFeatureTests` can hold every arm without
    /// hosting a window.
    ///
    /// It opens on `EndpointTrafficRow.spokenLabel`'s composition — method, path, then the status or
    /// the failure — so the same request is announced the same way in both panels. It then says what
    /// that panel has no room to: this table's endpoint and scenario columns, whose distinction is
    /// the one the panel exists for. A row reading nothing after the status is a row where an em
    /// dash meaning *"nothing is configured for this call"* and one meaning *"a journey answered
    /// it"* are the same silence.
    ///
    /// The unnamed arms follow `endpointCell` exactly, including the last of them: an `.endpoint`
    /// outcome with no name is an endpoint that answered and has since been renamed or deleted, the
    /// cell draws an em dash, and there is no name left to speak.
    nonisolated static func spokenLabel(
        for log: RequestLog,
        endpointName: String?,
        scenarioName: String?,
        isSelected: Bool
    ) -> String {
        var label = "\(log.method.rawValue) \(log.path)"

        if let code = log.responseStatusCode {
            label += ", status \(code)"
        } else if let failureLabel = log.failureLabel {
            label += ", failed: \(failureLabel)"
        } else {
            label += ", no response"
        }

        if let endpointName {
            label += ", endpoint \(endpointName)"
        } else {
            switch log.outcome {
            case .unmatched: label += ", unmatched"
            case .blockedByJourney: label += ", blocked by journey"
            case .journey: label += ", answered by journey"
            case .endpoint: break
            }
        }

        if let scenarioName {
            label += ", scenario \(scenarioName)"
        }

        if isSelected {
            label += ", selected"
        }

        return label
    }
}
