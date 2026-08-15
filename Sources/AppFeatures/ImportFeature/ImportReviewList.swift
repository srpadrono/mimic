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

/// One row of a dense table — ``DSControlHeight/denseRow`` — and the fills and the ink that row
/// draws.
///
/// The token is what makes this row and the request log's match, rather than a sentence in each
/// file naming the other.
///
/// Internal rather than private so the contrast tests can measure *what the window paints* rather
/// than a copy of it. A bed list written out inside a test is the blind spot every contrast failure
/// in this repository has come through, and both values below are load-bearing.
enum ImportRow {
    static let height = DSControlHeight.denseRow

    /// The ink every warning on a candidate row is drawn in: the "Duplicate" pill, the "Binary body"
    /// and "Body dropped" flags, and the size of a body that will be dropped.
    ///
    /// ``DSColors/warningText``, not ``DSColors/warning``, for all four. The base amber is measured
    /// as a plain word on a plain surface, and a candidate row is neither — it stripes, it washes
    /// under the pointer, and the duplicate flag fills itself with a tint of its own colour. Read on
    /// the wash below, base amber lands at **4.43** against the ``DSColors/surfaceElevated`` token
    /// and **4.23** on a panel, both under the 4.5 this palette holds itself to, and it was 4.17 and
    /// 4.01 while that wash was drawn at full strength.
    ///
    /// On the system material a sheet is really painted with, the same word *clears* — by **0.02** at
    /// its worst, which is the thinnest margin anything in this palette passes on, and a margin that
    /// belongs to a surface no token in this app names. That is the whole argument for moving: the
    /// readability of a flag should not turn on which material a sheet turns out to have. This
    /// token's worst reading anywhere on the row is **5.69**, and
    /// `ImportReviewRowContrastTests` takes all of them, on every bed
    /// ``background(isHovered:rowIndex:)`` can produce, over each of the three candidate surfaces.
    ///
    /// The footer's two summary labels keep the base ``DSColors/warning``: nothing stripes or washes
    /// beneath them, which is the plain word on a plain surface that token is measured for.
    static let warningInk = DSColors.warningText

    /// The tint the "Duplicate" flag fills itself with — the same 12% `DSStatusPill` draws, written
    /// here because this flag is a word in a `Label` rather than a status pill. The tests assert the
    /// two numbers agree, which is what keeps a hand-drawn composite from drifting off the component
    /// that owns it.
    static let flagFillOpacity: Double = 0.12

    /// The fill a row wears: the pointer's wash, the zebra stripe, or nothing.
    ///
    /// Striped like the request log — at this density the eye needs help tracking one row across six
    /// columns — and hovered at the same strength, ``DSColors/accentSubtle`` at 60%. Full strength is
    /// what the request log reserves for a *selected* row, which is the strongest statement a row can
    /// make and not one to spend on the pointer passing over. The weaker wash is also what keeps the
    /// duplicate flag above AA on a dark sheet, where the full-strength bed reads 4.43.
    static func background(isHovered: Bool, rowIndex: Int) -> Color {
        if isHovered { return DSColors.accentSubtle.opacity(0.6) }
        return rowIndex % 2 == 0 ? .clear : DSColors.rowStripe
    }
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

            // Same class of warning as the size limit: a binary body — an image, a font, a
            // compressed payload — cannot be carried by a text mock body, so it is dropped on import.
            if candidates.contains(where: { $0.bodyIsBinary }) {
                Label("Some entries have binary bodies, which import without one", systemImage: "exclamationmark.triangle")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.warning)
                    .lineLimit(1)
                    .accessibilityIdentifier("import.binaryBodyWarning")
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
                    // The row's stable, index-addressable handle. Every other identifier on this
                    // row is suffixed with a UUID the parser minted this run, so a test cannot name
                    // a row before it has read one out of the tree; `rowIndex` is the position the
                    // table actually presents. It goes on the path rather than on the row group
                    // above, because that group already carries `import.candidate.<uuid>` and one
                    // view holds one identifier — a second modifier would take the UUID's place
                    // rather than sit beside it. The path is the row's identity anyway, which is
                    // what the type's own note says, so `import.candidate.index.3` reads out the
                    // path of the fourth row.
                    .accessibilityIdentifier("import.candidate.index.\(rowIndex)")

                // Every GraphQL candidate in a capture shares one path; without the operation the
                // review is a column of identical rows. Same rule the sidebar follows.
                if let operation = candidate.graphqlOperation, !operation.isEmpty {
                    Text(operation)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.accentText)
                        .lineLimit(1)
                        .accessibilityIdentifier("import.candidate.index.\(rowIndex).operation")
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
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).name")

            // Coloured text, not a filled pill. A 200 is an ordinary value, and a row where every
            // field is a chip has no emphasis left for the field that needs it.
            Text("\(candidate.statusCode)")
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.httpStatusColor(for: candidate.statusCode))
                .frame(width: ImportColumns.status, alignment: .leading)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).status")

            Text(candidate.bodySizeLabel)
                .font(DSTypography.caption)
                .foregroundStyle(candidate.bodySizeExceedsLimit ? ImportRow.warningInk : DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: ImportColumns.size, alignment: .leading)
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).size")

            flag
                .frame(width: ImportColumns.flag, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: ImportRow.height)
        .background(ImportRow.background(isHovered: isHovered, rowIndex: rowIndex))
        .contentShape(Rectangle())
        // The row lights up under the pointer, so the row answers the click — the whole line is the
        // target, not the 18pt checkbox at its leading edge. A surface that answers the pointer and
        // nothing else is a control you find by trial, and this one had the hover, the content shape
        // and the cross-fade already: everything except the action.
        //
        // A tap target rather than a `Button`, and without the `.isButton` trait a bare tap target
        // usually earns. A button here would swallow the checkbox inside itself, and the trait would
        // announce this `.contain` group — which carries no label of its own — as an unnamed button
        // beside the control it duplicates. The click and the checkbox are one action, and the
        // checkbox is the half that is already named ("Import GET /orders"), so that is the half
        // assistive technology keeps.
        .onTapGesture { candidate.isSelected.toggle() }
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
                // The 12% tint of its own colour is the hardest bed on the row, and the first reason
                // the flags take a text variant: base amber reads 3.96:1 on that composite over a
                // panel and 4.11 over the elevated surface. The other three warnings on the row take
                // the same ink — see ``ImportRow/warningInk`` for the beds that decided it.
                .foregroundStyle(ImportRow.warningInk)
                .padding(.horizontal, DSSpacing.xs)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.xs)
                        .fill(ImportRow.warningInk.opacity(ImportRow.flagFillOpacity))
                )
                // "Already covered", not "already exists": since `ImportRouteLedger`, a repeat is
                // flagged whether the cover is an endpoint the project holds or an earlier row of
                // this same import — and for a capture of real traffic the second is the common case.
                .help("This method and path is already covered — by an existing endpoint or an earlier row of this import")
                .accessibilityLabel("Duplicate — this method and path is already covered")
                // A name per branch rather than one shared `…flag`: the branches are mutually
                // exclusive, so which identifier is present *is* the assertion a test wants.
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).flag.duplicate")
        } else if candidate.bodyIsBinary {
            // Before the size branch, deliberately: a binary body's recorded size can also exceed
            // the limit, and binary is the more specific reason there is no body.
            Label("Binary body", systemImage: "exclamationmark.triangle")
                .font(DSTypography.caption)
                .foregroundStyle(ImportRow.warningInk)
                .lineLimit(1)
                .help("The captured body is binary, which a text mock cannot serve — the endpoint imports without it")
                .accessibilityLabel("Binary body — the endpoint imports without it")
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).flag.binaryBody")
        } else if candidate.bodySizeExceedsLimit {
            Label("Body dropped", systemImage: "exclamationmark.triangle")
                .font(DSTypography.caption)
                .foregroundStyle(ImportRow.warningInk)
                .lineLimit(1)
                .help("Response body exceeds the 1 MB limit — the endpoint imports without it")
                .accessibilityLabel("Response body exceeds the limit and will not be imported")
                .accessibilityIdentifier("import.candidate.index.\(rowIndex).flag.bodyDropped")
        } else {
            // Not decoration — this is what holds the column open, and without it the table's
            // headers sat above the wrong columns.
            //
            // Most rows are none of duplicate, binary or oversized, so every branch above was absent
            // and the builder produced an `EmptyView`. An `HStack` drops an `EmptyView` entirely,
            // taking the `.frame(width: ImportColumns.flag)` wrapped around it with it — so the row
            // gave its flexible path column 92pt the header never gave its own, and Name, Status and
            // Size each rendered about ninety points to the right of the title naming them. Only the
            // columns *before* the flexible one lined up, which is why it read as the headers being
            // wrong rather than the rows.
            Color.clear
        }
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
