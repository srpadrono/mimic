import SwiftUI
import Domain
import DesignSystem
import SpecImport

// MARK: - Column geometry

/// The review table's column widths, written once so the header and every row agree. Each width
/// includes the cell's own 8 pt padding on either side, as the design measures them.
private enum ImportColumns {
    static let toggle: CGFloat = 36
    static let method: CGFloat = 68
    static let host: CGFloat = 170
    static let status: CGFloat = 80
    static let size: CGFloat = 80
    static let note: CGFloat = 170
    // path is flexible and takes the remaining space

    /// The padding inside every cell, the shared table's.
    static let cellPadding = DSTable.cellPadding
    /// The inset of the header and the rows from the table's edges.
    static let inset = DSSpacing.md
}

private extension View {
    /// Sets a fixed-width cell: its content inside the cell's padding.
    func importCell(width: CGFloat, alignment: Alignment = .leading) -> some View {
        frame(width: width - ImportColumns.cellPadding * 2, alignment: alignment)
            .padding(.horizontal, ImportColumns.cellPadding)
    }

    /// Sets the flexible path cell.
    func importFlexibleCell() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ImportColumns.cellPadding)
    }
}

/// One row of the review table: its height, its fills, and the ink its warnings use.
///
/// Internal so the contrast tests measure what the window paints.
enum ImportRow {
    static let height = DSRowHeight.list

    /// The ink for every warning on a candidate row: the note chips and the size of a body that won't import.
    static let warningInk = DSColors.warning

    /// How far a row from a hidden host fades.
    static let hiddenOpacity = 0.45

    /// The fill a row wears: the pointer's wash, the zebra stripe, or nothing. The review has no
    /// selection, only checkboxes, so it takes the shared table's fill without one.
    static func background(isHovered: Bool, rowIndex: Int) -> Color {
        DSTable.rowFill(index: rowIndex, isHovered: isHovered)
    }

    /// Whether a candidate carries anything the reviewer should look at before importing.
    static func needsReview(_ candidate: ImportCandidate) -> Bool {
        candidate.isDuplicate
            || candidate.bodyIsBinary
            || candidate.bodySizeExceedsLimit
            || candidate.bodyIsUnavailable
            || candidate.statusCode == 206
            || ImportCommitter.rejection(for: candidate) != nil
    }

    /// Whether the candidate's body is left behind if it is imported: the rows drawn in orange.
    static func dropsBody(_ candidate: ImportCandidate) -> Bool {
        candidate.bodyIsBinary || candidate.bodySizeExceedsLimit || candidate.bodyIsUnavailable
    }

    /// A browser writes status 0 for a request that never got a response.
    static func hasNoResponse(_ candidate: ImportCandidate) -> Bool {
        candidate.statusCode == 0
    }

    /// For every duplicate, the 1-based row of the earlier candidate it repeats, when it repeats one
    /// in this import rather than an endpoint the project already has.
    static func repeatedRows(in candidates: [ImportCandidate]) -> [Int: Int] {
        struct Route: Hashable {
            let method: HTTPMethod
            let path: String
            let operation: String?
        }
        var firstRow: [Route: Int] = [:]
        var repeated: [Int: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            let route = Route(method: candidate.method, path: candidate.path, operation: candidate.graphqlOperation)
            if candidate.isDuplicate {
                if let earlier = firstRow[route] { repeated[index] = earlier + 1 }
            } else if firstRow[route] == nil {
                firstRow[route] = index
            }
        }
        return repeated
    }

    /// The one line the footer shows: why rows are held back, or how bodies are saved.
    static func footerNote(for candidates: [ImportCandidate]) -> String {
        if candidates.contains(where: dropsBody) {
            return "Rows marked in orange are unselected. Select one to import it without its body."
        }
        if candidates.contains(where: { $0.statusCode == 206 || ImportCommitter.rejection(for: $0) != nil }) {
            return "Rows marked Cannot import are refused even when selected. Hover one to see why."
        }
        if candidates.contains(where: \.isDuplicate) {
            return "Repeated routes start unselected. Select one to import it as well."
        }
        return "Text bodies are saved as captured. Hover a row and use the eye button to preview one."
    }

    /// Said beside every footer note, because a text body is imported exactly as captured.
    static let capturedBodyDisclosure =
        "Text bodies are saved as captured, credentials included. Preview one with the eye button before importing."
}

/// The review's host menu: which hosts a capture reached, and which ones are switched off.
///
/// A row from a hidden host stays in the list, faded and unselected, so the capture still reads as
/// a whole; switching its host back on restores the selection the row had.
enum ImportHostFilter {
    struct Host: Equatable {
        let name: String
        let count: Int
    }

    /// Every host the candidates name, busiest first.
    static func hosts(in candidates: [ImportCandidate]) -> [Host] {
        var counts: [String: Int] = [:]
        for host in candidates.compactMap(\.host) { counts[host, default: 0] += 1 }
        return counts.map { Host(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static func isHidden(_ candidate: ImportCandidate, hiddenHosts: Set<String>) -> Bool {
        candidate.host.map(hiddenHosts.contains) ?? false
    }

    /// Switches a host on or off. Hiding a host deselects its rows and remembers what they were;
    /// showing it again puts that back.
    static func setHost(
        _ host: String,
        shown: Bool,
        candidates: inout [ImportCandidate],
        hiddenHosts: inout Set<String>,
        heldSelection: inout [UUID: Bool]
    ) {
        guard shown == hiddenHosts.contains(host) else { return }
        if shown {
            hiddenHosts.remove(host)
        } else {
            hiddenHosts.insert(host)
        }
        for index in candidates.indices where candidates[index].host == host {
            let id = candidates[index].id
            if shown {
                if let held = heldSelection.removeValue(forKey: id) { candidates[index].isSelected = held }
            } else {
                heldSelection[id] = candidates[index].isSelected
                candidates[index].isSelected = false
            }
        }
    }

    /// The menu's label: the busiest host shown, and how many more are shown beside it.
    static func title(hosts: [Host], hiddenHosts: Set<String>) -> (primary: String, more: String?) {
        let shown = hosts.filter { !hiddenHosts.contains($0.name) }
        guard let first = shown.first else { return ("No hosts", nil) }
        let others = shown.count - 1
        return (first.name, others == 0 ? nil : "+\(others) host\(others == 1 ? "" : "s")")
    }
}

/// Shared review list for import flows (HAR and OpenAPI): a filter bar, a dense table with one
/// line per candidate, and a footer with one note and the commit action.
struct ImportReviewList: View {
    @Binding var candidates: [ImportCandidate]
    @Binding var hiddenHosts: Set<String>
    let cancelIdentifier: String
    let onCancel: () -> Void
    let onImport: () -> Void

    private enum Scope: Hashable {
        case all
        case selected
        case needsReview
    }

    @State private var filterText = ""
    @State private var scope: Scope = .all
    /// What each hidden row was set to before its host was switched off.
    @State private var heldSelection: [UUID: Bool] = [:]

    public init(
        candidates: Binding<[ImportCandidate]>,
        hiddenHosts: Binding<Set<String>>,
        cancelIdentifier: String = "import.cancelButton",
        onCancel: @escaping () -> Void = {},
        onImport: @escaping () -> Void
    ) {
        self._candidates = candidates
        self._hiddenHosts = hiddenHosts
        self.cancelIdentifier = cancelIdentifier
        self.onCancel = onCancel
        self.onImport = onImport
    }

    public var body: some View {
        let visible = visibleIndices
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, DSSpacing.xl)
                .padding(.bottom, DSSpacing.md + 2)

            DSDivider(identifier: "import.summary")

            VStack(spacing: 0) {
                columnHeader(visible: visible)
                DSDivider(identifier: "import.columns")
                candidateList(visible: visible)
            }
            .background(DSColors.content)

            DSDivider(identifier: "import.footer")

            footer
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DSSpacing.md) {
            DSFilterField(
                text: $filterText,
                scopeID: .constant(""),
                scopes: [],
                placeholder: "Filter by path",
                label: "Filter endpoints by path",
                identifier: "import.filter"
            )
            .frame(minWidth: 140, maxWidth: 260)

            let hosts = ImportHostFilter.hosts(in: candidates)
            if !hosts.isEmpty {
                hostMenu(hosts)
            }

            DSSegmentedControl(
                "Show",
                segments: [
                    .init("All", value: Scope.all, identifier: "import.scope.all"),
                    .init("Selected", value: Scope.selected, count: selectedCount,
                          identifier: "import.scope.selected"),
                    .init("Needs review", value: Scope.needsReview, count: needsReviewCount,
                          countColor: needsReviewCount > 0 ? DSColors.warning : nil,
                          help: "Duplicates, bodies that will not import, and rows that cannot import",
                          identifier: "import.scope.needsReview")
                ],
                selection: $scope,
                identifier: "import.scope"
            )
            .fixedSize()

            Spacer(minLength: DSSpacing.sm)

            Text("\(selectedCount) of \(candidates.count) selected")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("import.selectionCount")
        }
    }

    /// A field-shaped menu listing every host with its request count, each one a switch.
    private func hostMenu(_ hosts: [ImportHostFilter.Host]) -> some View {
        let title = ImportHostFilter.title(hosts: hosts, hiddenHosts: hiddenHosts)
        return Menu {
            ForEach(hosts, id: \.name) { host in
                Toggle("\(host.name) (\(host.count))", isOn: hostBinding(host.name))
            }
            Divider()
            Button("Show all hosts") {
                for host in hosts { setHost(host.name, shown: true) }
            }
            .disabled(hiddenHosts.isEmpty)
        } label: {
            HStack(spacing: DSSpacing.xs + 2) {
                Text(title.primary)
                    .foregroundStyle(DSColors.labelPrimary)
                if let more = title.more {
                    Text(more)
                        .foregroundStyle(DSColors.labelTertiary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: DSGlyph.minimum, weight: .semibold))
                    .foregroundStyle(DSColors.labelTertiary)
                    .padding(.leading, DSSpacing.xxs)
                    .accessibilityHidden(true)
            }
            .font(DSTypography.callout)
            .lineLimit(1)
            .dsFieldChrome(height: DSControlHeight.regular, cornerRadius: DSControlHeight.regular / 2,
                           isFocused: false, horizontalPadding: DSSpacing.md)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which hosts to import from")
        .accessibilityIdentifier("import.hostMenu")
        .accessibilityLabel("Hosts")
        .accessibilityValue([title.primary, title.more].compactMap { $0 }.joined(separator: " "))
    }

    private func hostBinding(_ host: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenHosts.contains(host) },
            set: { setHost(host, shown: $0) }
        )
    }

    private func setHost(_ host: String, shown: Bool) {
        ImportHostFilter.setHost(
            host,
            shown: shown,
            candidates: &candidates,
            hiddenHosts: &hiddenHosts,
            heldSelection: &heldSelection
        )
    }

    // MARK: - Table

    private func columnHeader(visible: [Int]) -> some View {
        let selectable = visible.filter { !ImportHostFilter.isHidden(candidates[$0], hiddenHosts: hiddenHosts) }
        return HStack(spacing: 0) {
            // Selects or clears the rows currently shown; mixed when only some are selected.
            Toggle(sources: selectable.map { $candidates[$0] }, isOn: \.isSelected) {
                Text("Select shown endpoints")
            }
            .toggleStyle(.dsCheckbox)
            .labelsHidden()
            .disabled(selectable.isEmpty)
            .help("Select or clear the endpoints shown")
            .accessibilityIdentifier("import.selectShown")
            .importCell(width: ImportColumns.toggle)

            columnTitle("Method").importCell(width: ImportColumns.method)
            columnTitle("Path").importFlexibleCell()
            columnTitle("Host").importCell(width: ImportColumns.host)
            columnTitle("Status").importCell(width: ImportColumns.status)
            columnTitle("Size").importCell(width: ImportColumns.size, alignment: .trailing)
            columnTitle("Note").importCell(width: ImportColumns.note)
        }
        .padding(.horizontal, ImportColumns.inset)
        .frame(height: DSRowHeight.table + 2)
    }

    private func columnTitle(_ title: String) -> some View {
        DSTableColumnTitle(title)
            .accessibilityHidden(true)
    }

    /// A `ScrollView` over a `LazyVStack` rather than a `List`, so rows share the header's insets.
    private func candidateList(visible: [Int]) -> some View {
        let repeatedRows = ImportRow.repeatedRows(in: candidates)
        return ScrollView {
            LazyVStack(spacing: 0) {
                // `index` is the candidate's position in the full list, so row identifiers stay
                // stable while filtering; `position` drives the zebra stripe.
                ForEach(Array(visible.enumerated()), id: \.element) { position, index in
                    ImportCandidateRow(
                        candidate: $candidates[index],
                        rowIndex: index,
                        stripeIndex: position,
                        isHostHidden: ImportHostFilter.isHidden(candidates[index], hiddenHosts: hiddenHosts),
                        repeatsRow: repeatedRows[index]
                    )
                    .id(candidates[index].id)
                }
            }
            .padding(.horizontal, ImportColumns.inset)
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if visible.isEmpty {
                DSEmptyState(
                    heading: "No matching endpoints",
                    message: "Try a different filter.",
                    prominence: .compact,
                    identifier: "import.noMatches"
                )
            }
        }
        .accessibilityIdentifier("import.candidateList")
        // Paired so rows keep their own identifiers inside the list.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: DSSpacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: DSGlyph.button))
                .foregroundStyle(DSColors.labelTertiary)
                .help(ImportRow.capturedBodyDisclosure)
                .accessibilityHidden(true)

            Text(ImportRow.footerNote(for: candidates))
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ImportRow.capturedBodyDisclosure)
                .accessibilityIdentifier("import.footerNote")
                .accessibilityHint(ImportRow.capturedBodyDisclosure)

            DSButton("Cancel", variant: .secondary, size: .large, identifier: "import.cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            // Applied outside, so it wins over the `ds.button.…` name.
            .accessibilityIdentifier(cancelIdentifier)
            .accessibilityLabel("Cancel")

            DSButton(
                "Import \(selectedCount) endpoint\(selectedCount == 1 ? "" : "s")",
                variant: .primary,
                size: .large,
                identifier: "import.commit"
            ) {
                onImport()
            }
            .disabled(selectedCount == 0)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("import.importButton")
            .accessibilityLabel("Import selected endpoints")
            .accessibilityValue("\(selectedCount) selected")
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, DSSpacing.md + 2)
    }

    // MARK: - Model

    private var visibleIndices: [Int] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.indices.filter { index in
            let candidate = candidates[index]
            switch scope {
            case .all: break
            case .selected: if !candidate.isSelected { return false }
            case .needsReview: if !ImportRow.needsReview(candidate) { return false }
            }
            guard !query.isEmpty else { return true }
            return candidate.path.localizedCaseInsensitiveContains(query)
                || candidate.suggestedName.localizedCaseInsensitiveContains(query)
                || (candidate.host?.localizedCaseInsensitiveContains(query) ?? false)
                || (candidate.graphqlOperation?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedCount: Int {
        candidates.filter(\.isSelected).count
    }

    private var needsReviewCount: Int {
        candidates.filter(ImportRow.needsReview).count
    }
}

/// Single row in the import review table.
private struct ImportCandidateRow: View {
    @Binding var candidate: ImportCandidate
    /// Position in the full candidate list; used for the stable `import.candidate.index.<n>` handles.
    let rowIndex: Int
    /// Position among the rows shown; drives the zebra stripe.
    let stripeIndex: Int
    /// The row's host is switched off: it is shown faded and cannot be selected.
    let isHostHidden: Bool
    /// The 1-based row this duplicate repeats, or `nil` when it repeats an endpoint already in the project.
    let repeatsRow: Int?

    @State private var isHovered = false
    @State private var showingBodyPreview = false
    @FocusState private var previewFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cells
            if let rejection = ImportCommitter.rejection(for: candidate), !ImportRow.hasNoResponse(candidate) {
                Text(rejection)
                    .font(DSTypography.caption)
                    .foregroundStyle(ImportRow.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, ImportColumns.toggle + ImportColumns.method + ImportColumns.cellPadding)
                    .padding(.trailing, DSSpacing.sm)
                    .padding(.bottom, DSSpacing.sm)
                    .accessibilityIdentifier("import.candidate.index.\(rowIndex).validation")
            }
        }
        .opacity(isHostHidden ? ImportRow.hiddenOpacity : 1)
        .background(ImportRow.background(isHovered: isHovered && !isHostHidden, rowIndex: stripeIndex))
        .contentShape(Rectangle())
        // The checkbox is the named keyboard action; clicking elsewhere on the row toggles it too.
        .onTapGesture { if !isHostHidden { candidate.isSelected.toggle() } }
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.candidate.\(candidate.id.uuidString)")
    }

    private var cells: some View {
        HStack(spacing: 0) {
            // A real label so VoiceOver does not announce unnamed checkboxes.
            Toggle("Import \(candidate.method.rawValue) \(candidate.path)", isOn: $candidate.isSelected)
                .toggleStyle(.dsCheckbox)
                .labelsHidden()
                .disabled(isHostHidden)
                .accessibilityIdentifier("import.toggle.\(candidate.id.uuidString)")
                .importCell(width: ImportColumns.toggle)

            DSMethodLabel(candidate.method.rawValue, identifier: candidate.id.uuidString)
                .importCell(width: ImportColumns.method)

            pathCell
                .importFlexibleCell()

            hostCell
                .importCell(width: ImportColumns.host)

            statusCell
                .importCell(width: ImportColumns.status)

            Text(ImportRow.hasNoResponse(candidate) ? "\u{2014}" : candidate.bodySizeLabel)
                .font(DSTypography.Figure.regular)
                .foregroundStyle(ImportRow.dropsBody(candidate) ? ImportRow.warningInk : DSColors.labelSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).size")
                .importCell(width: ImportColumns.size, alignment: .trailing)

            note
                .importCell(width: ImportColumns.note)
        }
        .frame(height: ImportRow.height)
    }

    private var pathCell: some View {
        HStack(spacing: DSSpacing.xs) {
            Text(candidate.path)
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                // The row's stable, index-addressable handle for tests.
                .accessibilityIdentifier("import.candidate.index.\(rowIndex)")

            // GraphQL candidates share one path; the operation tells them apart.
            if let operation = candidate.graphqlOperation, !operation.isEmpty {
                Text(operation)
                    .font(DSTypography.code)
                    .foregroundStyle(DSColors.accent)
                    .lineLimit(1)
                    .accessibilityIdentifier("import.candidate.index.\(rowIndex).operation")
            }

            Spacer(minLength: 0)

            if let body = candidate.responseBody, !body.isEmpty {
                // Drawn on the row under the pointer or with keyboard focus, so the table rests as
                // the design draws it. The button itself stays, clear, for VoiceOver and the keyboard.
                Button {
                    showingBodyPreview = true
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: DSGlyph.field))
                        .foregroundStyle(isHovered || previewFocused || showingBodyPreview
                                         ? DSColors.labelTertiary : Color.clear)
                        .frame(width: DSControlHeight.small, height: DSControlHeight.small)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dsPlain)
                .focused($previewFocused)
                .help("Preview response body")
                .accessibilityLabel("Preview response body for \(candidate.method.rawValue) \(candidate.path)")
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).preview")
                .popover(isPresented: $showingBodyPreview) {
                    ImportBodyPreview(responseBody: body) { showingBodyPreview = false }
                }
            }
        }
    }

    private var hostCell: some View {
        Text(candidate.host ?? "\u{2014}")
            .font(DSTypography.callout)
            .foregroundStyle(candidate.host == nil ? DSColors.labelTertiary : DSColors.labelSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("import.candidate.index.\(rowIndex).host")
    }

    @ViewBuilder
    private var statusCell: some View {
        if ImportRow.hasNoResponse(candidate) {
            Text("\u{2014}")
                .font(DSTypography.status)
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityLabel("No response")
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).status")
        } else {
            DSStatusLabel(statusCode: candidate.statusCode)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).status")
        }
    }

    /// The one fact on the row that needs attention, as a small chip.
    @ViewBuilder
    private var note: some View {
        if isHostHidden {
            Text("Host hidden")
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelTertiary)
                .lineLimit(1)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).flag.hostHidden")
        } else if candidate.statusCode == 206 {
            ImportNoteChip("Partial response", identifier: "import.candidate.index.\(rowIndex).flag.partialResponse")
        } else if ImportRow.hasNoResponse(candidate) {
            ImportNoteChip("Response incomplete", identifier: "import.candidate.index.\(rowIndex).flag.noResponse")
                .help("The capture has no response for this request, so there is nothing to replay.")
                .accessibilityLabel("Response incomplete — the capture has no response to replay")
        } else if ImportCommitter.rejection(for: candidate) != nil {
            ImportNoteChip("Cannot import", identifier: "import.candidate.index.\(rowIndex).flag.invalid")
        } else if candidate.bodyIsUnavailable {
            ImportNoteChip("Response incomplete", identifier: "import.candidate.index.\(rowIndex).flag.bodyUnavailable")
                .help("The capture records a response body but omits its text. Selecting this endpoint imports without a body.")
                .accessibilityLabel("Response incomplete — selecting this endpoint imports without a body")
        } else if candidate.bodyIsBinary {
            // Before the size branch: binary is the more specific reason there is no body.
            ImportNoteChip("Binary body", identifier: "import.candidate.index.\(rowIndex).flag.binaryBody")
                .help("The captured body is binary, which a text mock cannot serve — the endpoint imports without it")
                .accessibilityLabel("Binary body — the endpoint imports without it")
        } else if candidate.bodySizeExceedsLimit {
            ImportNoteChip("Over 1 MB", identifier: "import.candidate.index.\(rowIndex).flag.bodyDropped")
                .help("Response body exceeds the 1 MB limit — the endpoint imports without it")
                .accessibilityLabel("Response body exceeds the limit and will not be imported")
        } else if candidate.isDuplicate {
            ImportNoteChip(
                repeatsRow.map { "Same route as row \($0)" } ?? "Already in project",
                isWarning: false,
                identifier: "import.candidate.index.\(rowIndex).flag.duplicate"
            )
            .help("This method and path is already covered — by an existing endpoint or an earlier row of this import")
            .accessibilityLabel("Duplicate — this method and path is already covered")
        } else {
            // Holds the column open; an empty branch would collapse its frame and shift the columns.
            Color.clear
        }
    }

    /// Carries the name and group the endpoint will be filed under, and any reason it is refused.
    private var helpText: String {
        var text = "\(candidate.method.rawValue) \(candidate.path)\nName: \(candidate.suggestedName)"
        if let group = candidate.suggestedGroupTag, !group.isEmpty {
            text += "\nGroup: \(group)"
        }
        if isHostHidden {
            text += "\nHidden by the host menu, so it won't be imported"
        } else if let rejection = ImportCommitter.rejection(for: candidate) {
            text += "\n\(rejection)"
        }
        return text
    }
}

/// A small note in the review table's last column: amber for a warning, neutral otherwise.
private struct ImportNoteChip: View {
    let title: String
    let isWarning: Bool
    let identifier: String

    init(_ title: String, isWarning: Bool = true, identifier: String) {
        self.title = title
        self.isWarning = isWarning
        self.identifier = identifier
    }

    var body: some View {
        DSPill(title, tone: isWarning ? .warning : .neutral, weight: .medium)
            .accessibilityIdentifier(identifier)
    }
}

/// A bounded, read-only view of the text that will be saved.
private struct ImportBodyPreview: View {
    let responseBody: String
    let onClose: () -> Void

    var body: some View {
        // Bound text layout; cutting at a Unicode scalar keeps the preview valid text.
        let preview = String(String.UnicodeScalarView(responseBody.unicodeScalars.prefix(16_384)))
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Response body")
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
            ScrollView([.horizontal, .vertical]) {
                Text(preview)
                    .font(DSTypography.code)
                    .foregroundStyle(DSColors.labelPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSSpacing.sm)
                    .accessibilityIdentifier("import.bodyPreview.text")
            }
            .frame(height: 240)
            .background(
                RoundedRectangle(cornerRadius: DSCornerRadius.field).fill(DSColors.code)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSCornerRadius.field)
                    .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
            )
            if preview.utf8.count < responseBody.utf8.count {
                Text("Preview shortened. Review the original file for the complete body.")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("import.bodyPreview.truncated")
            }
            Text("Read only. To change this body before importing, edit the source file.")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
            HStack {
                Spacer()
                DSButton("Close", variant: .secondary, size: .medium, identifier: "import.bodyPreview.close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: DSSheetWidth.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.bodyPreview")
    }
}
