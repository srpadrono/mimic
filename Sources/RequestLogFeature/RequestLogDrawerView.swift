import AppKit
import Observation
import SwiftUI
import Domain
import DesignSystem

// MARK: - Public View

/// The live traffic table: everything the server has answered. Docked under the editor it is a list;
/// selecting a row moves it into the centre column with `showsDetail`, the list on the left and the
/// selected request's detail on the right.
public struct RequestLogDrawerView: View {
    let requestLogs: [RequestLog]
    let endpoints: [Endpoint]
    let serverState: ServerState
    let onClear: () -> Void
    /// The selected rows. Owned by `WorkspaceView`, which opens the detail while there are any. A
    /// set, because ⌘- and ⇧-click pick calls out of a session to capture as a journey.
    @Binding var selectedLogIDs: Set<UUID>
    /// The Unmatched segment. Owned outside so the toolbar's unmatched badge can switch it on.
    @Binding var unmatchedOnly: Bool
    /// Creates a mock for a request that matched nothing.
    var onCreateEndpoint: ((HTTPMethod, String) -> Void)?
    var onSaveAsMock: ((UUID) -> Void)?
    /// Journeys the selected requests can be appended to.
    var journeys: [Journey] = []
    /// Appends the requests to an existing journey, copying the responses they received.
    var onAddToJourney: (([RequestLog], UUID) -> Void)?
    /// Seeds a new journey with the requests.
    var onAddToNewJourney: (([RequestLog]) -> Void)?
    /// The port the project serves on when it runs, for the empty log's `curl` hint while stopped.
    /// Set with ``configuredPort(_:)``.
    private(set) var configuredPort: Int?

    /// The filter, the sort and the rows they produced. Held in an object rather than in `@State`
    /// fields so the log docked under the editor and the log that takes over the centre column while
    /// a request is open read one table: selecting a row swaps one for the other, and the filter
    /// you used to find that row has to survive the swap.
    private let sharedTable: RequestLogTableState?
    /// Used only when no shared table was handed in, as in a preview or a rendering test.
    @State private var ownTable: RequestLogTableState
    private var table: RequestLogTableState { sharedTable ?? ownTable }
    @State private var filterDebounceTask: Task<Void, Never>?
    /// Beside the table, the selected request's detail. The centre column's arrangement while a
    /// request is open; the docked log never splits.
    var showsDetail = false
    /// Opens the endpoint that answered a request.
    var onGoToEndpoint: ((UUID) -> Void)?
    @FocusState private var filterFieldIsFocused: Bool
    /// Whether the table holds keyboard focus. The table is one focus target, like an AppKit table,
    /// and the arrow keys, Return, Escape and ⌘A below depend on it.
    @FocusState private var tableHasKeyboardFocus: Bool

    private var filterText: String {
        get { table.filterText }
        nonmutating set { table.filterText = newValue }
    }
    private var methodFilter: HTTPMethod? {
        get { table.methodFilter }
        nonmutating set { table.methodFilter = newValue }
    }
    /// The Errors segment. Unlike Unmatched, nothing outside the log switches it.
    private var errorsOnly: Bool {
        get { table.errorsOnly }
        nonmutating set { table.errorsOnly = newValue }
    }
    private var sortField: SortField {
        get { table.sortField }
        nonmutating set { table.sortField = newValue }
    }
    private var sortAscending: Bool {
        get { table.sortAscending }
        nonmutating set { table.sortAscending = newValue }
    }
    private var sortedAndFilteredLogs: [RequestLog] {
        get { table.rows }
        nonmutating set { table.rows = newValue }
    }
    /// Where a ⇧-click measures its range from: the last row clicked without ⇧.
    private var selectionAnchorID: UUID? {
        get { table.selectionAnchorID }
        nonmutating set { table.selectionAnchorID = newValue }
    }

    public init(
        requestLogs: [RequestLog],
        endpoints: [Endpoint],
        serverState: ServerState,
        onClear: @escaping () -> Void,
        selectedLogIDs: Binding<Set<UUID>> = .constant([]),
        unmatchedOnly: Binding<Bool> = .constant(false),
        onCreateEndpoint: ((HTTPMethod, String) -> Void)? = nil,
        onSaveAsMock: ((UUID) -> Void)? = nil,
        journeys: [Journey] = [],
        onAddToJourney: (([RequestLog], UUID) -> Void)? = nil,
        onAddToNewJourney: (([RequestLog]) -> Void)? = nil,
        table: RequestLogTableState? = nil,
        showsDetail: Bool = false,
        onGoToEndpoint: ((UUID) -> Void)? = nil
    ) {
        self.init(
            requestLogs: requestLogs,
            endpoints: endpoints,
            serverState: serverState,
            onClear: onClear,
            selectedLogIDs: selectedLogIDs,
            unmatchedOnly: unmatchedOnly,
            onCreateEndpoint: onCreateEndpoint,
            onSaveAsMock: onSaveAsMock,
            journeys: journeys,
            onAddToJourney: onAddToJourney,
            onAddToNewJourney: onAddToNewJourney,
            initialFilterText: "",
            initialMethodFilter: nil,
            initialSortField: .timestamp,
            initialSortAscending: false,
            table: table,
            showsDetail: showsDetail,
            onGoToEndpoint: onGoToEndpoint
        )
    }

    init(
        requestLogs: [RequestLog],
        endpoints: [Endpoint],
        serverState: ServerState,
        onClear: @escaping () -> Void,
        selectedLogIDs: Binding<Set<UUID>> = .constant([]),
        unmatchedOnly: Binding<Bool> = .constant(false),
        onCreateEndpoint: ((HTTPMethod, String) -> Void)? = nil,
        onSaveAsMock: ((UUID) -> Void)? = nil,
        journeys: [Journey] = [],
        onAddToJourney: (([RequestLog], UUID) -> Void)? = nil,
        onAddToNewJourney: (([RequestLog]) -> Void)? = nil,
        initialFilterText: String,
        initialMethodFilter: HTTPMethod?,
        initialSortField: SortField,
        initialSortAscending: Bool,
        table: RequestLogTableState? = nil,
        showsDetail: Bool = false,
        onGoToEndpoint: ((UUID) -> Void)? = nil
    ) {
        self.requestLogs = requestLogs
        self.endpoints = endpoints
        self.serverState = serverState
        self.onClear = onClear
        _selectedLogIDs = selectedLogIDs
        _unmatchedOnly = unmatchedOnly
        self.onCreateEndpoint = onCreateEndpoint
        self.onSaveAsMock = onSaveAsMock
        self.journeys = journeys
        self.onAddToJourney = onAddToJourney
        self.onAddToNewJourney = onAddToNewJourney
        self.showsDetail = showsDetail
        self.onGoToEndpoint = onGoToEndpoint
        self.sharedTable = table
        _ownTable = State(initialValue: RequestLogTableState(
            filterText: initialFilterText,
            methodFilter: initialMethodFilter,
            sortField: initialSortField,
            sortAscending: initialSortAscending
        ))
    }

    public var body: some View {
        GeometryReader { geometry in
            drawerContent(width: geometry.size.width)
        }
    }

    /// Below this the filter field moves out of the header onto a row of its own.
    private static let headerCollapseWidth: CGFloat = 700

    private func drawerContent(width: CGFloat) -> some View {
        let narrow = width < Self.headerCollapseWidth
        return VStack(spacing: 0) {
            header(narrow: narrow)

            if narrow && !requestLogs.isEmpty {
                filterControl
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.bottom, DSSpacing.sm)
            }

            if showsDetail {
                // The list keeps the four columns that identify a call; everything else about the
                // selected one is in the detail beside it.
                DSDivider(identifier: "requestLog.split")
                HStack(spacing: 0) {
                    logList(compact: true)
                        .frame(width: LogColumns.splitListWidth(totalWidth: width))
                    DSDivider(axis: .vertical, identifier: "requestLog.split.detail")
                    selectedRequestDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                logList(compact: width < LogColumns.minimumTableWidth)
            }
        }
        // No background of its own: the log sits on the centre column's content surface.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: filterText) { _, _ in updateLogs(debounce: true) }
        .onChange(of: methodFilter) { _, _ in updateLogs() }
        .onChange(of: unmatchedOnly) { _, _ in updateLogs() }
        .onChange(of: errorsOnly) { _, _ in updateLogs() }
        .onChange(of: sortField) { _, _ in updateLogs() }
        .onChange(of: sortAscending) { _, _ in updateLogs() }
        // The newest entry's identity, not the count: the buffer is capped at 1000, so from then on
        // the count never changes while the log keeps rotating.
        .onChange(of: requestLogs.last?.id) { _, _ in updateLogs() }
        .onChange(of: endpoints) { _, _ in updateLogs() }
        .onAppear {
            updateLogs()
            // The click that opened this arrangement was a click in the table, so the arrows carry
            // on from the row it selected.
            if showsDetail { tableHasKeyboardFocus = true }
        }
    }

    /// The table, or the state that stands in for it when there is nothing to list.
    @ViewBuilder
    private func logList(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if requestLogs.isEmpty {
                DSDivider(identifier: "drawer.empty")
                emptyLog
            } else if sortedAndFilteredLogs.isEmpty {
                DSDivider(identifier: "drawer.noMatches")
                DSEmptyState(
                    heading: "No matching requests",
                    message: "Adjust the filter to see results.",
                    prominence: .regular,
                    identifier: "drawer.noMatches"
                )
            } else {
                GeometryReader { tableGeometry in
                    let tableWidth = max(tableGeometry.size.width, LogColumns.compactMinimumTableWidth)
                    let pathWidth = LogColumns.pathWidth(tableWidth: tableWidth, compact: compact)
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            tableHeader(compact: compact, pathWidth: pathWidth)
                            tableBody(compact: compact, pathWidth: pathWidth, tableWidth: tableWidth)
                        }
                        .frame(width: tableWidth, height: tableGeometry.size.height)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Detail

    /// The request the detail beside the list describes: exactly one selected row that is still in
    /// the log. Names are resolved against the current project so they follow renames.
    private var selectedDetailContext: RequestDetailView.Context? {
        guard selectedLogIDs.count == 1,
              let id = selectedLogIDs.first,
              let log = requestLogs.first(where: { $0.id == id })
        else { return nil }
        return RequestDetailView.Context(
            log: log,
            endpointName: resolveEndpointName(log.matchedEndpointID),
            scenarioName: resolveScenarioName(endpointID: log.matchedEndpointID,
                                              scenarioID: log.matchedScenarioID),
            endpointExists: log.matchedEndpointID.map { id in endpoints.contains { $0.id == id } } ?? false,
            port: log.listenerPort ?? serverState.runningPort
        )
    }

    @ViewBuilder
    private var selectedRequestDetail: some View {
        if let context = selectedDetailContext {
            RequestDetailView(
                context: context,
                onCreateEndpoint: onCreateEndpoint,
                onSaveAsMock: onSaveAsMock,
                onGoToEndpoint: onGoToEndpoint,
                onClose: closeDetail,
                tabSelection: Bindable(table).detailTab
            )
            // A new request starts at the top of its own scroll position; the tab carries over.
            .id(context.log.id)
        } else if selectedLogIDs.count > 1 {
            DSEmptyState(
                heading: "\(selectedLogIDs.count) requests selected",
                message: "Select one request to inspect its headers and body.",
                actionTitle: "Close",
                prominence: .compact,
                identifier: "requestDetail.multipleRequests",
                action: closeDetail
            )
        } else {
            DSEmptyState(
                heading: "Request no longer in the log",
                message: "Older requests leave the log as new ones arrive.",
                actionTitle: "Close",
                prominence: .compact,
                identifier: "requestDetail.missing",
                action: closeDetail
            )
        }
    }

    /// Deselects everything, which gives the centre column back to the editor.
    private func closeDetail() {
        selectedLogIDs = []
        selectionAnchorID = nil
    }

    // MARK: - Header

    /// Title, count, the All / Unmatched / Errors control, the filter field and the clear button.
    ///
    /// The title never truncates. As the pane narrows the count goes first, then the segmented
    /// control drops onto a row of its own below the title.
    ///
    /// Carries the identifiers `DSPanelHeader` gives a panel header, which the UI suite addresses.
    @ViewBuilder
    private func header(narrow: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            headerRow(narrow: narrow, showsCount: true, showsScope: true)
            headerRow(narrow: narrow, showsCount: false, showsScope: true)
            VStack(alignment: .leading, spacing: 0) {
                headerRow(narrow: narrow, showsCount: true, showsScope: false)
                if !requestLogs.isEmpty {
                    // Under the title, on the header's own leading inset.
                    scopeControl
                        .padding(.leading, 14)
                        .padding(.trailing, DSSpacing.md)
                        .padding(.bottom, DSSpacing.sm)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.panelheader.requestLog")
    }

    private func headerRow(narrow: Bool, showsCount: Bool, showsScope: Bool) -> some View {
        HStack(spacing: DSSpacing.sm + DSSpacing.xxs) {
            Text("Request log")
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                .accessibilityIdentifier("ds.panelheader.title.requestLog")

            if showsCount, let shownCount {
                // The bare number, as the design draws it; the spoken label keeps its noun.
                Text(verbatim: "\(shownCount)")
                    .font(DSTypography.callout)
                    .monospacedDigit()
                    .foregroundStyle(DSColors.labelTertiary)
                    .lineLimit(1)
                    .help(Self.countLabel(shownCount))
                    .accessibilityLabel(Self.countLabel(shownCount))
                    .accessibilityIdentifier("ds.panelheader.subtitle.requestLog")
            }

            if showsScope, !requestLogs.isEmpty {
                scopeControl
                    .padding(.leading, DSSpacing.xs + DSSpacing.xxs)
            }

            Spacer(minLength: DSSpacing.sm)

            if !narrow {
                filterControl
                    .frame(width: 240)
                    // With nothing logged there is nothing to filter; the field stays as a quiet hint.
                    .disabled(requestLogs.isEmpty)
                    .opacity(requestLogs.isEmpty ? 0.5 : 1)
            }

            if !requestLogs.isEmpty {
                DSIconButton("Clear request log", systemImage: "trash", identifier: "clearRequestLogButton") {
                    selectedLogIDs = Self.performClear(onClear: onClear)
                    selectionAnchorID = nil
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, DSSpacing.md)
        .frame(height: DSBarHeight.paneHeader)
    }

    private var scopeControl: some View {
        DSSegmentedControl(
            "Show requests",
            segments: scopeSegments,
            selection: scopeSelection,
            identifier: "drawer.scope"
        )
    }

    private var scopeSegments: [DSSegmentedControl<LogScope>.Segment] {
        let unmatched = RequestLogQuery.unmatchedCount(logs: requestLogs)
        let errors = RequestLogQuery.errorCount(logs: requestLogs)
        return [
            .init("All", value: .all, help: "Show every request", identifier: "drawer.scope.all"),
            .init(
                "Unmatched",
                value: .unmatched,
                count: unmatched > 0 ? unmatched : nil,
                countColor: DSColors.warning,
                help: "Show only requests that matched no endpoint",
                identifier: "drawer.unmatchedFilter"
            ),
            .init(
                "Errors",
                value: .errors,
                count: errors > 0 ? errors : nil,
                countColor: DSColors.error,
                help: "Show only 4xx and 5xx responses and failed requests",
                identifier: "drawer.errorsFilter"
            ),
        ]
    }

    /// Unmatched maps onto the shared `unmatchedOnly` binding; Errors is local.
    private var scopeSelection: Binding<LogScope> {
        Binding(
            get: { unmatchedOnly ? .unmatched : (errorsOnly ? .errors : .all) },
            set: { scope in
                unmatchedOnly = scope == .unmatched
                errorsOnly = scope == .errors
            }
        )
    }

    /// A capsule filter well. The leading glyph is the method filter, as a filter field's scope menu.
    private var filterControl: some View {
        HStack(spacing: DSSpacing.xs + 2) {
            methodMenu

            TextField("Filter by path, status or scenario", text: Bindable(table).filterText)
                .textFieldStyle(.plain)
                .font(DSTypography.callout)
                .focused($filterFieldIsFocused)
                .accessibilityIdentifier("drawer.filterField")
                .accessibilityLabel("Filter request log")

            if !filterText.isEmpty {
                DSClearButton(
                    text: Binding(
                        get: { filterText },
                        set: {
                            filterText = $0
                            filterFieldIsFocused = true
                        }
                    ),
                    identifier: "drawer.clearFilter",
                    label: "Clear filter",
                    help: "Clear the filter"
                )
            }
        }
        .dsFieldChrome(height: DSControlHeight.regular, cornerRadius: DSControlHeight.regular / 2,
                       isFocused: filterFieldIsFocused)
    }

    /// The method filter: a magnifying glass at rest, the chosen method once one is picked.
    private var methodMenu: some View {
        Menu {
            Picker("Method", selection: Bindable(table).methodFilter) {
                Text("All").tag(HTTPMethod?.none)
                ForEach(HTTPMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(HTTPMethod?.some(method))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 2) {
                if let methodFilter {
                    Text(methodFilter.rawValue)
                        .font(DSTypography.method)
                        .foregroundStyle(DSColors.methodColor(for: methodFilter.rawValue))
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DSGlyph.field, weight: .regular))
                        .foregroundStyle(DSColors.labelTertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: DSGlyph.minimum, weight: .bold))
                    .foregroundStyle(DSColors.labelTertiary)
            }
            .frame(height: DSControlHeight.regular)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by method")
        .accessibilityIdentifier("drawer.methodFilter")
        .accessibilityLabel("Filter by method")
        .accessibilityValue(methodFilter?.rawValue ?? "All")
    }

    /// How many requests the table is showing, or `nil` for an empty log.
    private var shownCount: Int? {
        requestLogs.isEmpty ? nil : sortedAndFilteredLogs.count
    }

    /// "N requests", the count's spoken form.
    nonisolated static func countLabel(_ count: Int) -> String {
        "\(count) request\(count == 1 ? "" : "s")"
    }

    // MARK: - Empty log

    private var emptyLog: some View {
        VStack(spacing: DSSpacing.md) {
            Text("Requests appear here while the server runs")
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ds.empty.drawer.requests.heading")

            // Shown stopped too, as the design has it: the command is what to run once Run is
            // pressed, and it names the port the server will listen on.
            if let port = serverState.runningPort ?? configuredPort {
                curlChip("curl http://localhost:\(port)/")
            }
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.empty.drawer.requests")
    }

    /// The same drawer, naming `port` in the empty log's `curl` hint while the server is stopped.
    public func configuredPort(_ port: Int?) -> Self {
        var copy = self
        copy.configuredPort = port
        return copy
    }

    /// A command to try, in a code well with a copy button.
    private func curlChip(_ command: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Text(command)
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityIdentifier("drawer.empty.command")
            DSIconButton("Copy command", systemImage: "doc.on.doc", identifier: "drawer.empty.copyCommand") {
                RequestDetailView.write(command, to: .general)
            }
        }
        .padding(.leading, DSSpacing.md)
        .padding(.trailing, DSSpacing.xs)
        .padding(.vertical, DSSpacing.xs)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.segment)
                .fill(DSColors.code)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.segment)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
    }

    // MARK: - Table Header

    @ViewBuilder
    private func tableHeader(compact: Bool, pathWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            columnHeader("Time", field: .timestamp, width: LogColumns.timeWidth(compact: compact))
            columnHeader("Method", field: .method, width: LogColumns.method)
            columnHeader("Path", field: .path, width: pathWidth)
            columnHeader("Status", field: .status, width: LogColumns.status)
            if !compact {
                columnHeader("Scenario", field: .scenario, width: LogColumns.scenario)
                staticColumnHeader("Duration", width: LogColumns.duration)
                staticColumnHeader("Size", width: LogColumns.size)
            }
        }
        .padding(.horizontal, LogColumns.tableInset)
        .frame(height: DSRowHeight.table)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
        }
    }

    @ViewBuilder
    private func columnHeader(_ title: String, field: SortField, width: CGFloat) -> some View {
        SortableColumnHeader(
            title: title,
            isActive: sortField == field,
            isAscending: sortAscending,
            width: width,
            // Keyed on the sort field, so a relabelled column keeps the name tests hold.
            identifier: "drawer.columnHeader.\(field.rawValue)"
        ) {
            (sortField, sortAscending) = Self.nextSortState(
                currentField: sortField,
                currentAscending: sortAscending,
                requestedField: field
            )
        }
    }

    /// A numeric column that does not sort, right-aligned over its figures.
    private func staticColumnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(DSTypography.captionSemibold)
            .foregroundStyle(DSColors.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, DSSpacing.sm)
            .frame(width: width, alignment: .trailing)
    }

    // MARK: - Table Body

    @ViewBuilder
    private func tableBody(compact: Bool, pathWidth: CGFloat, tableWidth: CGFloat) -> some View {
        // Resolved once for the whole table; per row it would be O(rows²).
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
                            isEmphasized: tableHasKeyboardFocus,
                            compact: compact,
                            pathWidth: pathWidth,
                            onCreateEndpoint: onCreateEndpoint,
                            onSaveAsMock: onSaveAsMock,
                            journeys: journeys,
                            selection: selection,
                            onAddToJourney: onAddToJourney,
                            onAddToNewJourney: onAddToNewJourney,
                            port: log.listenerPort ?? serverState.runningPort,
                            onGoToEndpoint: onGoToEndpoint,
                            onShowOnlyPath: { filterText = RequestLogQuery.mockablePath(from: $0) },
                            endpointName: resolveEndpointName(log.matchedEndpointID),
                            scenarioName: resolveScenarioName(endpointID: log.matchedEndpointID, scenarioID: log.matchedScenarioID),
                            onSelect: { modifier in
                                // A click hands the table focus, so the arrows carry on from here.
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
                // Anchor the rows to the header's full width rather than the scrollbar-narrowed viewport.
                .frame(width: tableWidth, alignment: .leading)
            }
            .frame(width: tableWidth, alignment: .leading)
            // One focus target for the whole table; selection shows focus, so no ring.
            .focusable()
            .focusEffectDisabled()
            .focused($tableHasKeyboardFocus)
            // `.repeat` so a held arrow keeps moving; `.up` is absent or every press would run twice.
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape, "a"], phases: [.down, .repeat]) { press in
                handleKeyPress(press, displayOrder: displayOrder, proxy: proxy)
            }
        }
    }

    /// Arrow keys, Return, Escape and ⌘A, while the table holds focus. The decision is the pure
    /// ``nextSelection(key:extending:current:anchor:displayOrder:)``; a declined press is `.ignored`.
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

        // Unanimated, so the row is on screen before the next repeated key press arrives.
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
        // Unmatched wins when the toolbar badge switches it on while Errors was chosen.
        let currentErrorsOnly = errorsOnly && !unmatchedOnly
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
                    errorsOnly: currentErrorsOnly,
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

// MARK: - Column Header

/// One sortable column title: 11pt semibold, with a chevron on the sorted column. The direction
/// rides in the accessibility value so the label stays "Sort by <column>".
private struct SortableColumnHeader: View {
    let title: String
    let isActive: Bool
    let isAscending: Bool
    let width: CGFloat
    let identifier: String
    let sort: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: sort) {
            HStack(spacing: DSSpacing.xxs) {
                Text(title)
                    .font(DSTypography.captionSemibold)
                    .lineLimit(1)
                    .foregroundStyle(isActive || isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)

                if isActive {
                    Image(systemName: isAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: DSGlyph.minimum, weight: .bold))
                        .foregroundStyle(DSColors.labelSecondary)
                }
            }
            // The whole cell is the target, not only the word.
            .padding(.horizontal, DSSpacing.sm)
            .frame(width: width, height: DSRowHeight.table, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
        .help("Sort by \(title.lowercased())")
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Sort by \(title.lowercased())")
        .accessibilityValue(sortStateAnnouncement)
    }

    private var sortStateAnnouncement: String {
        guard isActive else { return "" }
        return isAscending ? "sorted ascending" : "sorted descending"
    }
}

// MARK: - Table Row

struct RequestLogTableRow: View {
    let log: RequestLog
    let rowIndex: Int
    let isSelected: Bool
    /// Whether the table has focus. A selected row in a focused table is filled with the accent and
    /// its text turns white; otherwise the selection is the quiet inactive fill, as in AppKit.
    var isEmphasized = true
    var compact = false
    /// The live table supplies its measured Path width; standalone rows size it naturally.
    var pathWidth: CGFloat? = nil
    var onCreateEndpoint: ((HTTPMethod, String) -> Void)?
    var onSaveAsMock: ((UUID) -> Void)? = nil
    @State private var showingSaveConfirmation = false
    var journeys: [Journey] = []
    /// Every selected row, in display order, so a right-click on one of them can act on all of them.
    var selection: [RequestLog] = []
    var onAddToJourney: (([RequestLog], UUID) -> Void)?
    var onAddToNewJourney: (([RequestLog]) -> Void)?
    /// The port the call arrived on, for the copied URL and cURL command.
    var port: Int? = nil
    var onGoToEndpoint: ((UUID) -> Void)? = nil
    /// Filters the log to this row's path.
    var onShowOnlyPath: ((String) -> Void)? = nil
    let endpointName: String?
    let scenarioName: String?
    let onSelect: (RequestLogDrawerView.SelectionModifier) -> Void
    @State private var isHovered = false

    /// What a capture acts on: the whole selection when this row belongs to a multi-row one,
    /// otherwise just this row. A right-click outside the selection never acts on the selection.
    private var capturable: [RequestLog] {
        selection.count > 1 && selection.contains(where: { $0.id == log.id }) ? selection : [log]
    }

    private var isProminent: Bool { isSelected && isEmphasized }

    var body: some View {
        HStack(spacing: 0) {
            Text(log.timestamp, format: compact ? RequestLogQuery.compactTimestampFormat : RequestLogQuery.timestampFormat)
                .font(DSTypography.Figure.regular)
                .foregroundStyle(ink(DSColors.labelSecondary))
                .lineLimit(1)
                .cell(width: LogColumns.timeWidth(compact: compact))

            // Keyed by the log entry, not the method, so every GET row has its own identifier.
            DSMethodLabel(log.method.rawValue, fixedWidth: false, identifier: log.id.uuidString)
                .cell(width: LogColumns.method)

            // Middle truncation keeps both the route's head and its last segment (often the id).
            Text(log.path)
                .font(DSTypography.code)
                .foregroundStyle(ink(DSColors.labelPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
                .cell(width: pathWidth)

            // `nil` is a transport failure, which the label draws as "Failed" in the error colour.
            DSStatusLabel(statusCode: log.responseStatusCode)
                .cell(width: LogColumns.status)

            if !compact {
                // No per-cell identifiers: the row ignores its children for accessibility, and
                // what these cells say is in `spokenLabel`.
                scenarioCell
                    .font(DSTypography.callout)
                    .lineLimit(1)
                    .cell(width: LogColumns.scenario)

                Text(log.durationMs.map(RequestLogQuery.formattedDuration) ?? "\u{2014}")
                    .font(DSTypography.Figure.regular)
                    .foregroundStyle(ink(DSColors.labelSecondary))
                    .lineLimit(1)
                    .cell(width: LogColumns.duration, alignment: .trailing)

                Text(RequestLogQuery.formattedSize(for: log) ?? "\u{2014}")
                    .font(DSTypography.Figure.regular)
                    .foregroundStyle(ink(DSColors.labelSecondary))
                    .lineLimit(1)
                    .cell(width: LogColumns.size, alignment: .trailing)
            }
        }
        .frame(height: DSRowHeight.table)
        .background(rowBackground)
        // Method and status labels turn white on the accent fill.
        .environment(\.backgroundProminence, isProminent ? .increased : .standard)
        .padding(.horizontal, LogColumns.tableInset)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(.current) }
        .onHover { isHovered = $0 }
        // One element with one spoken label; traits come after the element is formed. A tap target
        // rather than a `Button`, because a button would swallow the modifier chords selection uses.
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
        // Attached after the element is formed, so the menu's items stay reachable as elements.
        .alert("Save real response as mock?", isPresented: $showingSaveConfirmation) {
            Button("Save mock") { onSaveAsMock?(log.id) }
                .accessibilityIdentifier("requestLog.confirmSaveMock")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("requestLog.cancelSaveMock")
        } message: {
            Text("The saved response may contain private data. Review its body before sharing the project.")
        }
        .contextMenu {
            Button("Copy URL") {
                RequestDetailView.write(RequestDetailView.requestURL(for: log, port: port), to: .general)
            }
            .accessibilityIdentifier("requestLog.copyURL.\(log.id.uuidString)")

            Button("Copy as cURL") {
                RequestDetailView.write(RequestLogExport.curl(for: log, port: port), to: .general)
            }
            .disabled(RequestLogExport.curlUnavailability(for: log) != nil)
            .accessibilityIdentifier("requestLog.copyCurl.\(log.id.uuidString)")

            Button("Copy response body") {
                RequestDetailView.write(log.responseBody.map(RequestLogExport.formattedBody) ?? "", to: .general)
            }
            .disabled(log.responseBody?.isEmpty != false)
            .accessibilityIdentifier("requestLog.copyResponseBody.\(log.id.uuidString)")

            Divider()

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
            if log.outcome == .passthrough, onSaveAsMock != nil {
                Button("Save real response as mock") { showingSaveConfirmation = true }
                    .disabled((try? ResponseCapture.validate(log)) == nil)
                    .accessibilityIdentifier("requestLog.saveAsMock.\(log.id.uuidString)")
                    .accessibilityLabel("Save real response as mock")
            }

            // A journey-answered request is already in one; offering it again would duplicate a step.
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

            if onGoToEndpoint != nil || onShowOnlyPath != nil {
                Divider()
            }
            if let endpointID = log.matchedEndpointID, endpointName != nil, let onGoToEndpoint {
                Button("Go to endpoint") { onGoToEndpoint(endpointID) }
                    .accessibilityIdentifier("requestLog.goToEndpoint.\(log.id.uuidString)")
            }
            if let onShowOnlyPath {
                Button("Show only this path") { onShowOnlyPath(log.path) }
                    .accessibilityIdentifier("requestLog.showOnlyPath.\(log.id.uuidString)")
            }
        }
    }

    /// White on the accent selection, the given colour otherwise.
    private func ink(_ color: Color) -> Color {
        isProminent ? .white : color
    }

    private var rowBackground: Color {
        if isSelected { return isEmphasized ? DSColors.accent : DSColors.selectionInactive }
        if isHovered { return DSColors.hover }
        return rowIndex % 2 == 0 ? .clear : DSColors.zebra
    }

    /// The scenario that answered or, when none did, what did: unmatched in the warning colour,
    /// a journey, the real backend, or a failure.
    @ViewBuilder
    private var scenarioCell: some View {
        if let scenarioName {
            Text(scenarioName)
                .foregroundStyle(ink(DSColors.labelPrimary))
        } else {
            switch log.outcome {
            case .unmatched:
                Text(RequestOutcome.unmatched.label)
                    .foregroundStyle(ink(DSColors.warning))
            case .blockedByJourney:
                Text(RequestOutcome.blockedByJourney.label)
                    .foregroundStyle(ink(DSColors.warning))
            case .journey:
                Text(RequestOutcome.journey.label)
                    .foregroundStyle(ink(DSColors.accent))
            case .proxyFailure:
                Text(RequestOutcome.proxyFailure.label)
                    .foregroundStyle(ink(DSColors.error))
            case .passthrough:
                Text(log.backendName ?? RequestOutcome.passthrough.label)
                    .foregroundStyle(ink(DSColors.labelSecondary))
            case .endpoint:
                // An endpoint answered and has since been renamed or deleted, or no scenario resolved.
                Text(endpointName ?? "\u{2014}")
                    .foregroundStyle(ink(endpointName == nil ? DSColors.labelTertiary : DSColors.labelPrimary))
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


    /// What VoiceOver reads for the row: the request, what came back, what answered it, and whether
    /// it is in the selection. `static` so `WorkspaceFeatureTests` can hold every arm without
    /// hosting a window.
    ///
    /// It opens with the request — method, path, then the status or the failure — and then says what
    /// the table's endpoint and scenario columns show, whose distinction is the one the panel exists
    /// for. A row reading nothing after the status is a row where an em
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
            case .proxyFailure: label += ", backend unavailable"
            case .passthrough: label += ", passed through to real backend"
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
// MARK: - Cell geometry

private extension View {
    /// One table cell: `DSSpacing.sm` inside a fixed column, or the natural width when `nil`.
    func cell(width: CGFloat?, alignment: Alignment = .leading) -> some View {
        self
            .padding(.horizontal, DSSpacing.sm)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}
