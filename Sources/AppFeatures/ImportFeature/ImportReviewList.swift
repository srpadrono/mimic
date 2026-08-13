import SwiftUI
import Domain
import DesignSystem
import SpecImport

// MARK: - Column geometry

/// The one place the review table's column widths live.
///
/// Same shape as `LogColumns` in the request log, and for the same reason: a header row and a
/// hundred body rows have to agree on where a column starts, and they only stay agreeing if the
/// numbers are written once.
private enum ImportColumns {
    /// Matches the sidebar's method column, so a candidate and the endpoint it becomes line up.
    static let method: CGFloat = 58
    /// The name the endpoint will be created with.
    static let name: CGFloat = 120
    static let status: CGFloat = 34
    static let size: CGFloat = 58
    /// Wide enough for the "Duplicate" pill; the flag column is empty on most rows.
    static let flag: CGFloat = 92
    /// The checkbox, plus the gap the list puts either side of it.
    static let toggle: CGFloat = 18
    // path is flexible — takes the remaining space
}

/// One row of a dense table: 26pt, matching the request log.
private enum ImportRow {
    static let height: CGFloat = 26
}

/// Shared review list for import flows (HAR and OpenAPI).
///
/// Built for two hundred rows rather than three. A real HAR is a browsing session, so this is a
/// table, not a form: one line per candidate, a header naming the columns, and the four facts that
/// decide whether a row is wanted — method, path, status, and whether it already exists — each in a
/// fixed column you can scan down.
struct ImportReviewList: View {
    @Binding var candidates: [ImportCandidate]
    let onImport: () -> Void

    public init(candidates: Binding<[ImportCandidate]>, onImport: @escaping () -> Void) {
        self._candidates = candidates
        self.onImport = onImport
    }

    public var body: some View {
        // A `VStack`, because this used to be a bare `TupleView`: five siblings with no container,
        // laid out correctly only because the one caller happened to embed it in a stack. Rendered
        // anywhere else — a preview, a test host — the pieces landed on top of each other.
        VStack(spacing: 0) {
            header
            columnHeader

            // `.standard`, like the rule four lines below it and like every other band closer in the
            // window. This was the one the divider sweep missed.
            DSDivider(style: .standard, identifier: "import.summary")

            candidateList

            DSDivider(identifier: "import.footer")

            footer
        }
    }

    // MARK: - Chrome

    /// The panel's own controls, in the panel's own header — 30pt, title left, controls right, like
    /// every other panel in the app.
    ///
    /// "Select all" and "Deselect all" used to be `.plain` buttons in accent text sitting next to a
    /// label in the same size: nothing said they were controls except their colour, and they had no
    /// hit target beyond the width of the words.
    ///
    /// `.secondary` at `.small` is the panel-row well — 20pt, `DSCornerRadius.sm`, a 0.5pt hairline
    /// — so these two match each other and match the controls in the request log's header. Not
    /// `.ghost`: a ghost button is a link, which is what these already looked like and the reason
    /// nobody could find them.
    private var header: some View {
        DSPanelHeader("Endpoints found", identifier: "import.review") {
            HStack(spacing: DSSpacing.sm) {
                Text("\(selectedCount) of \(candidates.count) selected")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("import.selectionCount")

                DSButton(
                    "Select all",
                    variant: .secondary,
                    size: .small,
                    identifier: "import.selectAll"
                ) {
                    setAll(selected: true)
                }
                // A control that cannot change anything should say so rather than click emptily.
                .disabled(selectedCount == candidates.count)
                .accessibilityIdentifier("import.selectAll")
                .accessibilityLabel("Select all endpoints")

                DSButton(
                    "Deselect all",
                    variant: .secondary,
                    size: .small,
                    identifier: "import.deselectAll"
                ) {
                    setAll(selected: false)
                }
                .disabled(selectedCount == 0)
                .accessibilityIdentifier("import.deselectAll")
                .accessibilityLabel("Deselect all endpoints")
            }
        }
    }

    /// Names the columns. Five unlabelled ones read as a row of unrelated fragments — is "200" a
    /// status or a count? — and at two hundred rows you scan a column, not a row.
    private var columnHeader: some View {
        HStack(spacing: DSSpacing.sm) {
            Color.clear
                .frame(width: ImportColumns.toggle, height: 1)
                .accessibilityHidden(true)
            columnTitle("Method", width: ImportColumns.method)
            columnTitle("Path", width: nil)
            columnTitle("Name", width: ImportColumns.name)
            columnTitle("Status", width: ImportColumns.status)
            columnTitle("Size", width: ImportColumns.size)
            columnTitle("", width: ImportColumns.flag)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: DSBarHeight.columnHeader)
        // The same band the request log's column strip wears — the two are the same row doing the
        // same job, and until now they were the same magic `0.6` written out twice.
        .background(DSColors.band)
        .accessibilityHidden(true)
    }

    private func columnTitle(_ title: String, width: CGFloat?) -> some View {
        Text(title)
            .font(DSTypography.caption)
            // Column titles carry the meaning of the numbers under them — see the note above.
            .foregroundStyle(DSColors.labelSecondary)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: - List

    /// A `ScrollView` over a `LazyVStack` rather than a `List`, matching the request log. A `List`
    /// applies its own row insets, which a header row outside it cannot see — so the columns and
    /// their titles drifted apart by however much the platform felt like inserting that release.
    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Identity from the candidate, position from the enumeration — the same pairing the
                // request log uses, so a row keeps its state when the list is re-parsed and the
                // stripe still knows whether it is odd or even.
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, _ in
                    ImportCandidateRow(candidate: $candidates[index], rowIndex: index)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("import.candidateList")
        // Paired: the identifier above would otherwise be reported by every row inside it, and the
        // per-row `import.toggle.<id>` identifiers would vanish from the accessibility tree.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DSSpacing.md) {
            // A real warning: these bodies are dropped on import, so something is lost.
            if candidates.contains(where: { $0.bodySizeExceedsLimit }) {
                Label("Some entries exceed the 1 MB body limit", systemImage: "exclamationmark.triangle")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.warning)
                    .lineLimit(1)
                    .accessibilityIdentifier("import.bodySizeWarning")
            }

            // Not a warning: nothing is wrong and nothing is lost, the rows are simply pre-answered.
            // It was amber, which made it indistinguishable at a glance from the line above it —
            // and a colour that means "look here" stops meaning anything once it is on everything.
            if candidates.contains(where: { $0.isDuplicate }) {
                Label("Duplicates are deselected by default", systemImage: "doc.on.doc")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("import.duplicateWarning")
            }

            Spacer(minLength: DSSpacing.md)

            DSButton(
                "Import \(selectedCount) endpoint\(selectedCount == 1 ? "" : "s")",
                variant: .primary,
                size: .medium,
                identifier: "import.commit"
            ) {
                onImport()
            }
            .disabled(selectedCount == 0)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("import.importButton")
            .accessibilityLabel("Import selected endpoints")
        }
        .padding(DSSpacing.md)
    }

    private var selectedCount: Int {
        candidates.filter(\.isSelected).count
    }

    private func setAll(selected: Bool) {
        for i in candidates.indices {
            candidates[i].isSelected = selected
        }
    }
}

/// Single row in the import review list.
///
/// The path is the row's identity, so it is the row's headline. It used to be the quietest thing on
/// the line — 36% alpha under a 13pt name that the importer had derived from that same path — which
/// meant the one fact that told two candidates apart was the one you had to squint at.
private struct ImportCandidateRow: View {
    @Binding var candidate: ImportCandidate
    let rowIndex: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            // A real label rather than `Toggle("")`: with an empty string VoiceOver announced two
            // hundred unnamed checkboxes.
            Toggle("Import \(candidate.method.rawValue) \(candidate.path)", isOn: $candidate.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: ImportColumns.toggle, alignment: .leading)
                .accessibilityIdentifier("import.toggle.\(candidate.id.uuidString)")

            DSMethodBadge(
                method: candidate.method.rawValue,
                size: .compact,
                identifier: candidate.id.uuidString
            )
            .frame(width: ImportColumns.method, alignment: .leading)

            HStack(spacing: DSSpacing.xs) {
                Text(candidate.path)
                    .font(DSTypography.code)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Every GraphQL candidate in a capture shares one path; without the operation the
                // review is a column of identical rows. Same rule the sidebar follows.
                if let operation = candidate.graphqlOperation, !operation.isEmpty {
                    Text(operation)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.accentText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // What the endpoint will be called once imported — the only thing on the row that is
            // about the result rather than the capture.
            Text(candidate.suggestedName)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: ImportColumns.name, alignment: .leading)

            // Coloured text, not a filled pill. A 200 is an ordinary value, and a row where every
            // field is a chip has no emphasis left for the field that needs it.
            Text("\(candidate.statusCode)")
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.httpStatusColor(for: candidate.statusCode))
                .frame(width: ImportColumns.status, alignment: .leading)

            Text(candidate.bodySizeLabel)
                .font(DSTypography.caption)
                .foregroundStyle(candidate.bodySizeExceedsLimit ? DSColors.warning : DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: ImportColumns.size, alignment: .leading)

            flag
                .frame(width: ImportColumns.flag, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: ImportRow.height)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.candidate.\(candidate.id.uuidString)")
    }

    /// The one thing on the row that needs attention gets the one filled pill.
    ///
    /// It was an amber `doc.on.doc` glyph whose only explanation was a tooltip, sitting beside an
    /// amber `exclamationmark.triangle` that meant something completely different. Now the duplicate
    /// says the word, so it survives being read in greyscale, and the oversized body colours the
    /// size it is complaining about instead of adding a second badge.
    @ViewBuilder
    private var flag: some View {
        if candidate.isDuplicate {
            Label("Duplicate", systemImage: "doc.on.doc")
                .font(DSTypography.caption)
                // `warningText`, not `warning`: this flag fills itself with a 12% tint of its own
                // colour, where the base amber reads 3.96:1 on a panel and 4.11 on the elevated
                // surface this sheet is. The "Body dropped" flag below stays `warning` — it is a
                // plain word on a plain surface, which is what that token is measured for.
                .foregroundStyle(DSColors.warningText)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                        .fill(DSColors.warningText.opacity(0.12))
                )
                // "Already covered", not "already exists": since `ImportRouteLedger`, a repeat is
                // flagged whether the cover is an endpoint the project holds or an earlier row of
                // this same import — and for a capture of real traffic the second is the common case.
                .help("This method and path is already covered — by an existing endpoint or an earlier row of this import")
                .accessibilityLabel("Duplicate — this method and path is already covered")
        } else if candidate.bodySizeExceedsLimit {
            Label("Body dropped", systemImage: "exclamationmark.triangle")
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.warning)
                .lineLimit(1)
                .help("Response body exceeds the 1 MB limit — the endpoint imports without it")
                .accessibilityLabel("Response body exceeds the limit and will not be imported")
        } else {
            // Not decoration — this is what holds the column open, and without it the table's
            // headers sat above the wrong columns.
            //
            // Most rows are neither a duplicate nor oversized, so both branches above were absent and
            // the builder produced an `EmptyView`. An `HStack` drops an `EmptyView` entirely, taking
            // the `.frame(width: ImportColumns.flag)` wrapped around it with it — so the row gave its
            // flexible path column 92pt the header never gave its own, and Name, Status and Size each
            // rendered about ninety points to the right of the title naming them. Only the columns
            // *before* the flexible one lined up, which is why it read as the headers being wrong
            // rather than the rows.
            Color.clear
        }
    }

    /// Striped like the request log: at this density the eye needs help tracking one row across six
    /// columns.
    private var rowBackground: Color {
        if isHovered { return DSColors.accentSubtle }
        return rowIndex % 2 == 0 ? .clear : DSColors.rowStripe
    }

    /// Carries what the row cannot: the group the endpoint will be filed under, which is derived
    /// from the path and so would only repeat it on screen.
    private var helpText: String {
        var text = "\(candidate.method.rawValue) \(candidate.path)"
        if let group = candidate.suggestedGroupTag, !group.isEmpty {
            text += "\nGroup: \(group)"
        }
        return text
    }
}
