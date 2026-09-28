import SwiftUI
import Domain
import DesignSystem
import SpecImport

// MARK: - Column geometry

/// The review table's column widths, written once so the header and every row agree.
private enum ImportColumns {
    static let toggle: CGFloat = 16
    static let method: CGFloat = DSLayout.methodColumn
    static let name: CGFloat = 144
    static let status: CGFloat = 56
    static let size: CGFloat = 64
    static let note: CGFloat = 144
    // path is flexible and takes the remaining space
}

/// One row of the review table: its height, its fills, and the ink its warnings use.
///
/// Internal so the contrast tests measure what the window paints.
enum ImportRow {
    static let height = DSRowHeight.list

    /// The ink for every warning on a candidate row: the note chips and an oversized body's size.
    static let warningInk = DSColors.warning

    /// The fill a row wears: the pointer's wash, the zebra stripe, or nothing.
    static func background(isHovered: Bool, rowIndex: Int) -> Color {
        if isHovered { return DSColors.hover }
        return rowIndex % 2 == 0 ? .clear : DSColors.zebra
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
}

/// Shared review list for import flows (HAR and OpenAPI): a filter bar, a dense table with one
/// line per candidate, and a footer with the notes and the commit action.
struct ImportReviewList: View {
    @Binding var candidates: [ImportCandidate]
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

    public init(
        candidates: Binding<[ImportCandidate]>,
        cancelIdentifier: String = "import.cancelButton",
        onCancel: @escaping () -> Void = {},
        onImport: @escaping () -> Void
    ) {
        self._candidates = candidates
        self.cancelIdentifier = cancelIdentifier
        self.onCancel = onCancel
        self.onImport = onImport
    }

    public var body: some View {
        let visible = visibleIndices
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, DSSpacing.xl)
                .padding(.bottom, DSSpacing.md)

            DSDivider(style: .standard, identifier: "import.summary")

            VStack(spacing: 0) {
                columnHeader(visible: visible)
                DSDivider(style: .standard, identifier: "import.columns")
                candidateList(visible: visible)
            }
            .background(DSColors.content)

            DSDivider(style: .standard, identifier: "import.footer")

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
            .frame(minWidth: 140, maxWidth: 240)

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

            Spacer(minLength: DSSpacing.sm)

            Text("\(selectedCount) of \(candidates.count) selected")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("import.selectionCount")

            DSButton("Select all", variant: .secondary, size: .medium, identifier: "import.selectAll") {
                setAll(selected: true)
            }
            .disabled(selectedCount == candidates.count)
            .accessibilityIdentifier("import.selectAll")
            .accessibilityLabel("Select all endpoints")

            DSButton("Deselect all", variant: .secondary, size: .medium, identifier: "import.deselectAll") {
                setAll(selected: false)
            }
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("import.deselectAll")
            .accessibilityLabel("Deselect all endpoints")
        }
    }

    // MARK: - Table

    private func columnHeader(visible: [Int]) -> some View {
        HStack(spacing: DSSpacing.sm) {
            // Selects or clears the rows currently shown; mixed when only some are selected.
            Toggle(sources: visible.map { $candidates[$0] }, isOn: \.isSelected) {
                Text("Select shown endpoints")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(.small)
            .disabled(visible.isEmpty)
            .frame(width: ImportColumns.toggle, alignment: .leading)
            .help("Select or clear the endpoints shown")
            .accessibilityIdentifier("import.selectShown")

            columnTitle("Method", width: ImportColumns.method)
            columnTitle("Path", width: nil)
            columnTitle("Name", width: ImportColumns.name)
            columnTitle("Status", width: ImportColumns.status)
            columnTitle("Size", width: ImportColumns.size, alignment: .trailing)
            columnTitle("Note", width: ImportColumns.note)
        }
        .padding(.horizontal, DSSpacing.md + DSSpacing.sm)
        .frame(height: DSRowHeight.table + 2)
    }

    private func columnTitle(_ title: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(DSTypography.captionSemibold)
            .foregroundStyle(DSColors.labelSecondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .accessibilityHidden(true)
    }

    /// A `ScrollView` over a `LazyVStack` rather than a `List`, so rows share the header's insets.
    private func candidateList(visible: [Int]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // `index` is the candidate's position in the full list, so row identifiers stay
                // stable while filtering; `position` drives the zebra stripe.
                ForEach(Array(visible.enumerated()), id: \.element) { position, index in
                    ImportCandidateRow(candidate: $candidates[index], rowIndex: index, stripeIndex: position)
                        .id(candidates[index].id)
                }
            }
            .padding(.horizontal, DSSpacing.md)
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
            // Notes stack so several can show at the sheet's minimum width.
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if candidates.contains(where: { $0.bodySizeExceedsLimit }) {
                    note("Bodies over 1 MB are deselected; selecting them imports without a body",
                         identifier: "import.bodySizeWarning")
                }
                if candidates.contains(where: { $0.bodyIsBinary }) {
                    note("Binary bodies are deselected; selecting them imports without a body",
                         identifier: "import.binaryBodyWarning")
                }
                if candidates.contains(where: { $0.bodyIsUnavailable }) {
                    note("Missing captured bodies are deselected; selecting them imports without a body",
                         identifier: "import.unavailableBodyWarning")
                }
                if candidates.contains(where: { $0.statusCode == 206 }) {
                    note("Partial responses cannot be imported; capture a complete response",
                         identifier: "import.partialResponseWarning")
                }
                if candidates.contains(where: { $0.statusCode != 206 && ImportCommitter.rejection(for: $0) != nil }) {
                    note("Some entries cannot be imported; review the reason below each row",
                         identifier: "import.invalidCandidateWarning")
                }
                // Duplicates are pre-answered, not an error, so the note is neutral.
                if candidates.contains(where: { $0.isDuplicate }) {
                    note("Duplicates are deselected by default", systemImage: "doc.on.doc",
                         tint: DSColors.labelTertiary, identifier: "import.duplicateWarning")
                }
                Text("Text bodies are saved as captured. Use the eye button to preview them before importing.")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.capturedBodyNotice")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DSButton("Cancel", variant: .secondary, size: .large, identifier: "import.cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
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
        .padding(.vertical, DSSpacing.md)
    }

    private func note(
        _ text: String,
        systemImage: String = "exclamationmark.triangle.fill",
        tint: Color = DSColors.warning,
        identifier: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: DSGlyph.field))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
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
                || (candidate.graphqlOperation?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedCount: Int {
        candidates.filter(\.isSelected).count
    }

    private var needsReviewCount: Int {
        candidates.filter(ImportRow.needsReview).count
    }

    private func setAll(selected: Bool) {
        for i in candidates.indices {
            candidates[i].isSelected = selected
        }
    }
}

/// Single row in the import review table.
private struct ImportCandidateRow: View {
    @Binding var candidate: ImportCandidate
    /// Position in the full candidate list; used for the stable `import.candidate.index.<n>` handles.
    let rowIndex: Int
    /// Position among the rows shown; drives the zebra stripe.
    let stripeIndex: Int

    @State private var isHovered = false
    @State private var showingBodyPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cells
            if let rejection = ImportCommitter.rejection(for: candidate) {
                Text(rejection)
                    .font(DSTypography.caption)
                    .foregroundStyle(ImportRow.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, ImportColumns.toggle + ImportColumns.method + DSSpacing.sm * 2 + DSSpacing.sm)
                    .padding(.trailing, DSSpacing.sm)
                    .padding(.bottom, DSSpacing.sm)
                    .accessibilityIdentifier("import.candidate.index.\(rowIndex).validation")
            }
        }
        .background(ImportRow.background(isHovered: isHovered, rowIndex: stripeIndex))
        .contentShape(Rectangle())
        // The checkbox is the named keyboard action; clicking elsewhere on the row toggles it too.
        .onTapGesture { candidate.isSelected.toggle() }
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.candidate.\(candidate.id.uuidString)")
    }

    private var cells: some View {
        HStack(spacing: DSSpacing.sm) {
            // A real label so VoiceOver does not announce unnamed checkboxes.
            Toggle("Import \(candidate.method.rawValue) \(candidate.path)", isOn: $candidate.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: ImportColumns.toggle, alignment: .leading)
                .accessibilityIdentifier("import.toggle.\(candidate.id.uuidString)")

            DSMethodLabel(candidate.method.rawValue, identifier: candidate.id.uuidString)
                .frame(width: ImportColumns.method, alignment: .leading)

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
                    Button {
                        showingBodyPreview = true
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: DSGlyph.field))
                            .foregroundStyle(isHovered ? DSColors.accent : DSColors.labelTertiary)
                            .frame(width: DSControlHeight.small, height: DSControlHeight.small)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.dsPlain)
                    .help("Preview response body")
                    .accessibilityLabel("Preview response body for \(candidate.method.rawValue) \(candidate.path)")
                    .accessibilityIdentifier("import.candidate.index.\(rowIndex).preview")
                    .popover(isPresented: $showingBodyPreview) {
                        ImportBodyPreview(responseBody: body) { showingBodyPreview = false }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // What the endpoint will be called once imported.
            Text(candidate.suggestedName)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: ImportColumns.name, alignment: .leading)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).name")

            DSStatusLabel(statusCode: candidate.statusCode)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).status")
                .frame(width: ImportColumns.status, alignment: .leading)

            Text(candidate.bodySizeLabel)
                .font(DSTypography.Figure.regular)
                .foregroundStyle(candidate.bodySizeExceedsLimit ? ImportRow.warningInk : DSColors.labelSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).size")
                .frame(width: ImportColumns.size, alignment: .trailing)

            note
                .frame(width: ImportColumns.note, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(height: ImportRow.height)
    }

    /// The one fact on the row that needs attention, as a small chip.
    @ViewBuilder
    private var note: some View {
        if candidate.statusCode == 206 {
            ImportNoteChip("Partial response", identifier: "import.candidate.index.\(rowIndex).flag.partialResponse")
        } else if ImportCommitter.rejection(for: candidate) != nil {
            ImportNoteChip("Cannot import", identifier: "import.candidate.index.\(rowIndex).flag.invalid")
        } else if candidate.bodyIsUnavailable {
            ImportNoteChip("Body unavailable", identifier: "import.candidate.index.\(rowIndex).flag.bodyUnavailable")
                .help("The capture records a response body but omits its text. Selecting this endpoint imports without a body.")
                .accessibilityLabel("Body unavailable — selecting this endpoint imports without a body")
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
            ImportNoteChip("Duplicate", isWarning: false, identifier: "import.candidate.index.\(rowIndex).flag.duplicate")
                .help("This method and path is already covered — by an existing endpoint or an earlier row of this import")
                .accessibilityLabel("Duplicate — this method and path is already covered")
        } else {
            // Holds the column open; an empty branch would collapse its frame and shift the columns.
            Color.clear
        }
    }

    /// Carries the group the endpoint will be filed under, which would only repeat the path on screen.
    private var helpText: String {
        var text = "\(candidate.method.rawValue) \(candidate.path)"
        if let group = candidate.suggestedGroupTag, !group.isEmpty {
            text += "\nGroup: \(group)"
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
        Text(title)
            .font(DSTypography.caption.weight(.medium))
            .foregroundStyle(isWarning ? ImportRow.warningInk : DSColors.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(isWarning ? DSColors.warningBackground : DSColors.field))
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
