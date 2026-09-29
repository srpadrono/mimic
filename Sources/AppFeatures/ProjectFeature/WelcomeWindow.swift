import SwiftUI
import Domain
import DesignSystem

/// Welcome window: the app's identity and start actions on the left, projects on the right.
///
/// The window draws under its own title bar, as the design does: the traffic lights sit in the left
/// column and no title is shown, so the geometry below is measured from the top of the window.
struct WelcomeWindow: View {
    let recentProjects: [RecentProjectEntry]
    let onOpenProject: (UUID) -> Void
    let onDuplicateProject: (UUID) -> Void
    let onDeleteProject: (UUID) -> Void
    let onRequestRenameProject: (RecentProjectEntry) -> Void
    /// Asks the root to present the new-project sheet. `ContentView` owns the sheet so the menu and
    /// this button open the same one.
    let onRequestNewProject: () -> Void
    /// Optional start actions. A row is shown only when its handler is provided.
    let onRequestImport: ((ImportKind) -> Void)?
    let onRequestOpenExport: (() -> Void)?
    let onRequestSampleProject: (() -> Void)?
    /// "Show this window when Mimic opens". The checkbox is shown only when this is provided.
    let showsOnLaunch: Binding<Bool>?

    @State private var viewState: ViewState
    /// The row the keyboard is on. Kept out of `ViewState`, which holds only modal state.
    @State private var selectedRecentID: UUID?
    /// Whether the recents list has keyboard focus, so the arrow keys and Return reach it.
    @FocusState private var isRecentsFocused: Bool

    struct DeleteTarget: Identifiable {
        let id: UUID
        let name: String
    }

    struct ViewState {
        var deleteTarget: DeleteTarget?

        var deleteAlertTitle: String {
            "Delete \"\(deleteTarget?.name ?? "")\"?"
        }

        static let deleteMessage = "This will permanently remove the project and all its endpoints. This action cannot be undone."

        mutating func clearDeleteTarget(isPresented: Bool) {
            if !isPresented {
                deleteTarget = nil
            }
        }

        mutating func beginDeleting(_ entry: RecentProjectEntry) {
            deleteTarget = DeleteTarget(id: entry.id, name: entry.name)
        }
    }

    init(
        recentProjects: [RecentProjectEntry],
        onOpenProject: @escaping (UUID) -> Void,
        onDuplicateProject: @escaping (UUID) -> Void,
        onDeleteProject: @escaping (UUID) -> Void,
        onRequestRenameProject: @escaping (RecentProjectEntry) -> Void = { _ in },
        onRequestNewProject: @escaping () -> Void,
        onRequestImport: ((ImportKind) -> Void)? = nil,
        onRequestOpenExport: (() -> Void)? = nil,
        onRequestSampleProject: (() -> Void)? = nil,
        showsOnLaunch: Binding<Bool>? = nil
    ) {
        self.init(
            recentProjects: recentProjects,
            onOpenProject: onOpenProject,
            onDuplicateProject: onDuplicateProject,
            onDeleteProject: onDeleteProject,
            onRequestRenameProject: onRequestRenameProject,
            onRequestNewProject: onRequestNewProject,
            onRequestImport: onRequestImport,
            onRequestOpenExport: onRequestOpenExport,
            onRequestSampleProject: onRequestSampleProject,
            showsOnLaunch: showsOnLaunch,
            initialDeleteTarget: nil
        )
    }

    init(
        recentProjects: [RecentProjectEntry],
        onOpenProject: @escaping (UUID) -> Void,
        onDuplicateProject: @escaping (UUID) -> Void,
        onDeleteProject: @escaping (UUID) -> Void,
        onRequestRenameProject: @escaping (RecentProjectEntry) -> Void = { _ in },
        onRequestNewProject: @escaping () -> Void,
        onRequestImport: ((ImportKind) -> Void)? = nil,
        onRequestOpenExport: (() -> Void)? = nil,
        onRequestSampleProject: (() -> Void)? = nil,
        showsOnLaunch: Binding<Bool>? = nil,
        initialDeleteTarget: DeleteTarget?
    ) {
        self.recentProjects = recentProjects
        self.onOpenProject = onOpenProject
        self.onDuplicateProject = onDuplicateProject
        self.onDeleteProject = onDeleteProject
        self.onRequestRenameProject = onRequestRenameProject
        self.onRequestNewProject = onRequestNewProject
        self.onRequestImport = onRequestImport
        self.onRequestOpenExport = onRequestOpenExport
        self.onRequestSampleProject = onRequestSampleProject
        self.showsOnLaunch = showsOnLaunch
        _viewState = State(initialValue: ViewState(deleteTarget: initialDeleteTarget))
    }

    var body: some View {
        GeometryReader { geometry in
            let heroWidth = min(400, max(300, geometry.size.width * 0.45))
            // 112 at the design's 560pt height, smaller in a short window so the actions still fit.
            let iconSize = min(112, max(64, geometry.size.height * 0.2))

            HStack(spacing: 0) {
                leftColumn(iconSize: iconSize, isShort: geometry.size.height < 520)
                    .frame(width: heroWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(DSColors.content)

                DSDivider(axis: .vertical, identifier: "welcome.columns")

                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(DSColors.sheet)
            }
        }
        // The title bar is part of the columns rather than a band above them.
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 640, minHeight: 380)
        .alert(
            viewState.deleteAlertTitle,
            isPresented: Binding(
                get: { viewState.deleteTarget != nil },
                set: { viewState.clearDeleteTarget(isPresented: $0) }
            ),
            presenting: viewState.deleteTarget
        ) { target in
            Button("Delete project", role: .destructive) {
                Self.deleteProject(target: target, onDeleteProject: onDeleteProject)
            }
            Button("Keep project", role: .cancel) { }
        } message: { _ in
            // The title is a `String`, so the message carries the identifier.
            Text(ViewState.deleteMessage)
                .accessibilityIdentifier("welcome.deleteAlert.message")
        }
    }

    var currentViewState: ViewState {
        viewState
    }

    // MARK: - Left column

    /// From the top of the window: 16pt of padding, the 20pt traffic-light row, then 36pt of air.
    private static let heroTopInset: CGFloat = DSSpacing.lg + DSSpacing.xl + DSSpacing.xxxl + DSSpacing.xs

    private func leftColumn(iconSize: CGFloat, isShort: Bool) -> some View {
        VStack(spacing: 0) {
            hero(iconSize: iconSize)
            actions
                .padding(.top, isShort ? DSSpacing.lg : DSSpacing.xxl + DSSpacing.xs)
            Spacer(minLength: 0)
        }
        // A short window keeps the traffic-light clearance and gives up the air under it.
        .padding(.top, isShort ? DSSpacing.lg + DSSpacing.xl + DSSpacing.md : Self.heroTopInset)
        .padding(.horizontal, DSSpacing.xxxl)
        .padding(.bottom, DSSpacing.xxl + DSSpacing.xs)
    }

    private func hero(iconSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image("MimicLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                // App-icon squircle, not a control corner, so it scales with the icon.
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.23, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 15, y: 10)
                // The title below says "Mimic"; VoiceOver should not read it twice.
                .accessibilityHidden(true)

            Text("Mimic")
                .font(DSTypography.largeTitle)
                .foregroundStyle(DSColors.labelPrimary)
                .padding(.top, DSSpacing.md + DSSpacing.xs + DSSpacing.xxs)
                .accessibilityIdentifier("welcomeHeroTitle")

            if let versionText {
                Text(versionText)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .padding(.top, DSSpacing.xs + DSSpacing.xxs)
                    .accessibilityIdentifier("welcomeVersionLabel")
            }
        }
    }

    private var actions: some View {
        VStack(spacing: DSSpacing.xxs) {
            WelcomeActionRow(
                icon: "plus",
                title: "New project\u{2026}",
                shortcut: "\u{2318}N",
                help: "Create a new mock server project",
                identifier: "newProjectButton",
                action: onRequestNewProject
            )

            if let onRequestImport {
                // One row for both formats, as the design has it; the menu asks which.
                Menu {
                    Button("HAR file\u{2026}") { onRequestImport(.har) }
                        .accessibilityIdentifier("welcome.import.har")
                        .accessibilityLabel("Import HAR file")
                    Button("OpenAPI spec\u{2026}") { onRequestImport(.openAPI) }
                        .accessibilityIdentifier("welcome.import.openAPI")
                        .accessibilityLabel("Import OpenAPI spec")
                } label: {
                    WelcomeActionLabel(
                        icon: "square.and.arrow.down",
                        title: "Import HAR or OpenAPI\u{2026}",
                        shortcut: nil
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Create a project from a HAR file or an OpenAPI spec")
                .accessibilityIdentifier("welcome.import")
                .accessibilityLabel("Import HAR or OpenAPI\u{2026}")
            }

            if let onRequestOpenExport {
                WelcomeActionRow(
                    icon: "folder",
                    title: "Open project export\u{2026}",
                    shortcut: "\u{2318}O",
                    help: "Open a Mimic project export",
                    identifier: "welcome.openExport",
                    action: onRequestOpenExport
                )
            }

            if let onRequestSampleProject {
                WelcomeActionRow(
                    icon: "star",
                    title: "Try the sample project",
                    shortcut: nil,
                    help: "Open a sample project with endpoints and a journey",
                    identifier: "welcome.sampleProject",
                    action: onRequestSampleProject
                )
            }
        }
    }

    /// Read from the bundle. `nil` (no line) when the key is missing, as in a unit-test host.
    private var versionText: String? {
        guard
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else {
            return nil
        }
        return "Version \(version)"
    }

    // MARK: - Right column

    /// From the top of the window, level with the design's list caption.
    private static let recentsTopInset: CGFloat = DSSpacing.xxxl + DSSpacing.md

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            recentsHeader

            if recentProjects.isEmpty {
                emptyRecents
                    .frame(maxHeight: .infinity)
            } else {
                recentsList
            }

            if let showsOnLaunch {
                Toggle("Show this window when Mimic opens", isOn: showsOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.top, DSSpacing.sm)
                    .accessibilityIdentifier("welcome.showOnLaunch")
                    .accessibilityLabel("Show this window when Mimic opens")
            }
        }
        .padding(.top, Self.recentsTopInset)
        .padding([.horizontal, .bottom], DSSpacing.md)
    }

    private var recentsHeader: some View {
        Text("Recent projects")
            .font(DSTypography.captionSemibold)
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, DSSpacing.md)
            .padding(.bottom, DSSpacing.sm)
            .accessibilityIdentifier("welcome.recents.header")
    }

    private var emptyRecents: some View {
        DSEmptyState(
            systemImage: "clock",
            heading: "No projects yet",
            message: "Create one to define mock endpoints and start a server.",
            identifier: "welcome.recents"
        )
    }

    /// A stack rather than a `List`: the design selects a row with a rounded accent inset, where a
    /// native list draws a full-width band. The keyboard behaviour a list gives for free is kept by
    /// hand: the stack takes focus, the arrow keys move the selection, and Return opens it.
    private var recentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: DSSpacing.xxs) {
                    ForEach(recentProjects) { entry in
                        recentRow(entry)
                            .id(entry.id)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // A click in the empty space below the rows gives the list keyboard focus; a click on a
            // row opens it, so this is the only way to focus the list with the pointer.
            .contentShape(Rectangle())
            .onTapGesture { isRecentsFocused = true }
            .focusable()
            .focused($isRecentsFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.return) { openSelectedRecent() }
            // `.contain` before the identifier so naming the list does not rename the rows.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("welcome.recents.list")
            .onAppear {
                selectedRecentID = Self.validSelection(selectedRecentID, in: recentProjects)
                isRecentsFocused = true
            }
            // Keep the selection on a row that still exists after a delete.
            .onChange(of: recentProjects) { _, entries in
                selectedRecentID = Self.validSelection(selectedRecentID, in: entries)
            }
            .onChange(of: selectedRecentID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func recentRow(_ entry: RecentProjectEntry) -> some View {
        RecentProjectRow(entry: entry, isSelected: entry.id == selectedRecentID)
            // The whole row is clickable, not only its text.
            .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
            .onTapGesture {
                // Selection follows the pointer too, so Return acts on the row last touched.
                selectedRecentID = entry.id
                Self.openProject(id: entry.id, onOpenProject: onOpenProject)
            }
            .contextMenu {
                Button("Open") {
                    Self.openProject(id: entry.id, onOpenProject: onOpenProject)
                }
                .accessibilityIdentifier("welcome.recents.contextMenu.open")
                Button("Rename\u{2026}") { onRequestRenameProject(entry) }
                    .accessibilityIdentifier("welcome.recents.contextMenu.rename")
                Divider()
                Button("Duplicate") {
                    Self.duplicateProject(id: entry.id, onDuplicateProject: onDuplicateProject)
                }
                .accessibilityIdentifier("welcome.recents.contextMenu.duplicate")
                Divider()
                Button("Delete project\u{2026}", role: .destructive) {
                    selectedRecentID = entry.id
                    viewState.beginDeleting(entry)
                }
                .accessibilityIdentifier("welcome.recents.contextMenu.delete")
            }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let next = Self.selection(movedBy: offset, from: selectedRecentID, in: recentProjects) else {
            return .ignored
        }
        selectedRecentID = next
        return .handled
    }

    private func openSelectedRecent() -> KeyPress.Result {
        guard let selectedRecentID else { return .ignored }
        Self.openProject(id: selectedRecentID, onOpenProject: onOpenProject)
        return .handled
    }

    /// The row `offset` rows away from `current`, clamped to the list. With nothing selected, the
    /// first row.
    static func selection(movedBy offset: Int, from current: UUID?, in entries: [RecentProjectEntry]) -> UUID? {
        guard !entries.isEmpty else { return nil }
        guard let current, let index = entries.firstIndex(where: { $0.id == current }) else {
            return entries.first?.id
        }
        let target = min(max(index + offset, 0), entries.count - 1)
        return entries[target].id
    }

    /// Keeps the selection on a row that exists: the current one if it survived, otherwise the top.
    static func validSelection(_ current: UUID?, in entries: [RecentProjectEntry]) -> UUID? {
        if let current, entries.contains(where: { $0.id == current }) {
            return current
        }
        return entries.first?.id
    }

    static func openProject(id: UUID, onOpenProject: (UUID) -> Void) {
        onOpenProject(id)
    }

    static func duplicateProject(id: UUID, onDuplicateProject: (UUID) -> Void) {
        onDuplicateProject(id)
    }

    static func deleteProject(target: DeleteTarget, onDeleteProject: (UUID) -> Void) {
        onDeleteProject(target.id)
    }
}

// MARK: - Action row

/// The look of a start action: an icon well, a title and an optional shortcut hint.
private struct WelcomeActionLabel: View {
    let icon: String
    let title: String
    let shortcut: String?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: DSGlyph.toolbar, weight: .medium))
                .foregroundStyle(DSColors.accent)
                .frame(width: DSControlHeight.large, height: DSControlHeight.large)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.field)
                        .fill(DSColors.field)
                )
                .accessibilityHidden(true)

            Text(title)
                .font(DSTypography.bodyMedium)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)

            Spacer(minLength: DSSpacing.sm)

            if let shortcut {
                Text(shortcut)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DSSpacing.md)
        // 40pt: the 28pt well and 6pt above and below it.
        .frame(height: DSControlHeight.large + DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .fill(isHovered ? DSColors.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
    }
}

/// A start action that runs when clicked.
private struct WelcomeActionRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    let help: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WelcomeActionLabel(icon: icon, title: title, shortcut: shortcut)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

// MARK: - Recent project row

private struct RecentProjectRow: View {
    let entry: RecentProjectEntry
    let isSelected: Bool
    @State private var isHovered = false

    /// The design's row: 52pt, a 32pt monogram tile, the name over a summary, the date on the right.
    private static let height: CGFloat = DSRowHeight.recent + DSSpacing.sm

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Text(Self.initials(for: entry.name))
                .font(DSTypography.bodySemibold)
                .foregroundStyle(.white)
                .frame(width: DSControlHeight.prominent, height: DSControlHeight.prominent)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.segment)
                        .fill(Self.tileColor(for: entry.id))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(entry.name)
                    .font(DSTypography.bodySemibold)
                    .foregroundStyle(isSelected ? Color.white : DSColors.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(Self.detailText(for: entry))
                    .font(DSTypography.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : DSColors.labelSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("welcome.recents.detail")
            }

            Spacer(minLength: DSSpacing.sm)

            Text(Self.stampText(for: entry.lastOpenedAt))
                .font(DSTypography.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : DSColors.labelTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .fill(isSelected ? DSColors.accent : (isHovered ? DSColors.hover : .clear))
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
        .help(Self.fullStampText(for: entry.lastOpenedAt))
        // `.contain` keeps the name and dates addressable inside the row.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recentProject-\(entry.name)")
        .accessibilityLabel("\(entry.name), last opened \(Self.relativeText(for: entry.lastOpenedAt))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// "Port 18086 · 12 endpoints · 3 journeys", from the store. Until the store has answered, the
    /// time the project was last opened.
    static func detailText(for entry: RecentProjectEntry) -> String {
        entry.summary?.text ?? "Last opened \(timeText(for: entry.lastOpenedAt))"
    }

    /// Up to two letters: the first letter of the first two words, or the first two letters.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters: String
        if words.count >= 2 {
            letters = String(words[0].prefix(1)) + String(words[1].prefix(1))
        } else if let word = words.first {
            letters = String(word.prefix(2))
        } else {
            letters = "?"
        }
        return letters.uppercased()
    }

    /// A stable colour per project, from its id, so a rename keeps it. `hashValue` changes between
    /// launches, so this sums the id's bytes instead.
    static func tileColor(for id: UUID) -> Color {
        DSColors.projectTiles[tileIndex(for: id)]
    }

    static func tileIndex(for id: UUID) -> Int {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return sum % DSColors.projectTiles.count
    }

    /// "yesterday", "3 days ago": used in the spoken label.
    static func relativeText(for date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// The time of day.
    static func timeText(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Today", "Yesterday", "Sep 21", or a numeric date in another year.
    static func stampText(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The full date and time, for the tooltip.
    static func fullStampText(for date: Date) -> String {
        "Last opened \(date.formatted(date: .long, time: .shortened))"
    }
}
