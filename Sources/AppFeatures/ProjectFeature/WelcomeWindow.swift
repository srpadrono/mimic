import SwiftUI
import Domain
import DesignSystem

/// Welcome screen — Xcode-style two-column layout with branding + actions on
/// the left and recent projects on the right.
///
/// This is the first thing anyone sees, so it follows the same rules as the workspace rather than
/// inventing its own: the recents pane is a panel and wears `DSPanelHeader`, every size and weight
/// comes from `DSTypography`, and the list is a list — selectable, arrow-navigable, Return to open.
struct WelcomeWindow: View {
    let recentProjects: [RecentProjectEntry]
    let onOpenProject: (UUID) -> Void
    let onDuplicateProject: (UUID) -> Void
    let onDeleteProject: (UUID) -> Void
    /// Asks the root to present the new-project sheet.
    ///
    /// The sheet used to live here, which made two presenters for one dialog once File ▸ New Project
    /// could open it from an open workspace too. `ContentView` owns it now, so the menu and this
    /// button reach the same sheet whichever branch is on screen.
    let onRequestNewProject: () -> Void

    @State private var viewState: ViewState
    /// The row the keyboard is on.
    ///
    /// Deliberately outside `ViewState`: that type is the window's *modal* state, and a selection
    /// that survives a sheet being presented is not part of it. Without a selection there was no
    /// keyboard path to a recent project at all — the list could only be reached with the pointer.
    @State private var selectedRecentID: UUID?

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

    public init(
        recentProjects: [RecentProjectEntry],
        onOpenProject: @escaping (UUID) -> Void,
        onDuplicateProject: @escaping (UUID) -> Void,
        onDeleteProject: @escaping (UUID) -> Void,
        onRequestNewProject: @escaping () -> Void
    ) {
        self.init(
            recentProjects: recentProjects,
            onOpenProject: onOpenProject,
            onDuplicateProject: onDuplicateProject,
            onDeleteProject: onDeleteProject,
            onRequestNewProject: onRequestNewProject,
            initialDeleteTarget: nil
        )
    }

    init(
        recentProjects: [RecentProjectEntry],
        onOpenProject: @escaping (UUID) -> Void,
        onDuplicateProject: @escaping (UUID) -> Void,
        onDeleteProject: @escaping (UUID) -> Void,
        onRequestNewProject: @escaping () -> Void,
        initialDeleteTarget: DeleteTarget?
    ) {
        self.recentProjects = recentProjects
        self.onOpenProject = onOpenProject
        self.onDuplicateProject = onDuplicateProject
        self.onDeleteProject = onDeleteProject
        self.onRequestNewProject = onRequestNewProject
        _viewState = State(initialValue: ViewState(deleteTarget: initialDeleteTarget))
    }

    public var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left column: branding + actions
            leftColumn
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(DSColors.dominant)

            // `.strong`, now that it means something: this separates the window's two full-height
            // columns, which is the heaviest job a rule in this app does. `.standard` reads as an
            // in-panel hairline and let the two halves run together.
            DSDivider(style: .strong, axis: .vertical)

            // MARK: - Right column: recent projects
            rightColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DSColors.secondary)
        }
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
            Text(ViewState.deleteMessage)
        }
    }

    var currentViewState: ViewState {
        viewState
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(spacing: DSSpacing.xxl) {
            Spacer(minLength: 0)
            hero
            actions
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.lg)
    }

    private var hero: some View {
        VStack(spacing: DSSpacing.md) {
            Image("MimicLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)
                // 28 is ~0.2237 × the icon's edge: the macOS app-icon squircle, not a UI corner.
                // Deliberately not a `DSCornerRadius` token — those are for controls and panels, and
                // rounding an app icon to 12 would make it look like a button.
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                // The title underneath says "Mimic"; without this VoiceOver says it twice, the
                // second time as the asset's filename.
                .accessibilityHidden(true)

            VStack(spacing: DSSpacing.xs) {
                // `DSTypography.display`, not `.system(size: 32, weight: .bold)`. 32pt bold existed
                // nowhere else in the app, so the one piece of type a new user reads first was the
                // one piece drawn outside the scale.
                Text("Mimic")
                    .font(DSTypography.display)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityIdentifier("welcomeHeroTitle")

                if let versionText {
                    Text(versionText)
                        .font(DSTypography.label)
                        // Not `labelTertiary`. At 36% alpha a version string is decoration; it is
                        // the first thing anyone quotes in a bug report.
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityIdentifier("welcomeVersionLabel")
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: DSSpacing.xxs) {
            ActionRow(
                icon: "plus.rectangle",
                title: "Create new project\u{2026}",
                help: "Create a new mock server project",
                identifier: "newProjectButton"
            ) {
                onRequestNewProject()
            }
        }
    }

    /// Read from the bundle rather than typed into the view.
    ///
    /// This line said "Version 1.0" while `MARKETING_VERSION` had moved on to 1.6.0 — the only
    /// number on the first screen, and it was wrong. `nil` (and so no line at all) when the key is
    /// missing, which is what a unit-test host looks like: a bare "Version" reads as a bug.
    private var versionText: String? {
        guard
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else {
            return nil
        }
        return "Version \(version)"
    }

    // MARK: - Right Column

    /// The recents pane is a panel, so it wears the same chrome the workspace panels do: one 30pt
    /// row, title left, count in the subtitle slot — and it stays when the list is empty, because
    /// chrome that disappears with its content reads as a rendering glitch.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "Projects", not "Recent projects". The list is reconciled against the store now rather
            // than read from the ten-entry `UserDefaults` cache, so it holds everything you have —
            // recency only decides the order. Calling it "recent" would promise less than it shows,
            // and would suggest there is somewhere else to look for the rest. There is not: this
            // window is the only way into a project.
            DSPanelHeader(
                "Projects",
                subtitle: recentCountSubtitle,
                identifier: "welcome.recents"
            )

            if recentProjects.isEmpty {
                emptyRecents
            } else {
                recentsList
            }
        }
    }

    /// `nil` rather than "0" when there is nothing to count — an empty panel does not need a number
    /// to tell you it is empty.
    private var recentCountSubtitle: String? {
        guard !recentProjects.isEmpty else { return nil }
        return "\(recentProjects.count)"
    }

    private var emptyRecents: some View {
        // Spacing, type scale and width cap all match `DSEmptyState`, which every other empty
        // state in the app uses. This one kept its own smaller scale — a 13pt heading against 16
        // and an 11pt message against 13, with no 320pt cap — so the first screen a new user sees
        // read a size smaller than the rest of the window. The structure stays hand-rolled only
        // because the UI suite asserts on these identifiers.
        VStack(spacing: DSSpacing.md) {
            // `.regular` at `labelSecondary`, matching `DSEmptyState.icon`. This was 24pt at `.light`
            // in `labelTertiary` — the combination `DSEmptyState` records having already fixed once:
            // a large, thin shape at 36% alpha reads as a smudge rather than as a symbol, and this
            // one greets every first-run user.
            //
            // Off the `DSGlyph` ladder on purpose, and the ladder says so itself: an illustration is
            // not a glyph. 26 is `DSEmptyState.glyphSize`, which this matches deliberately — folding
            // it in would turn a scale with a defensible top rung at 13 into an open-ended one.
            Image(systemName: "clock")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityHidden(true)

            // Sentence case. "No Recent Projects" was the only headline in the app still in title
            // case, and it is the one sentence a first-run user reads.
            Text("No projects yet")
                .font(DSTypography.heading)
                .foregroundStyle(DSColors.labelPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("noRecentProjectsLabel")

            // The empty state used to say only what was missing. Saying how it gets filled costs
            // one line and answers the question the previous version left open.
            Text("Create one to define mock endpoints and start a server.")
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("noRecentProjectsHint")
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentsList: some View {
        List(recentProjects, selection: $selectedRecentID) { entry in
            RecentProjectRow(entry: entry)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // Without this the row responded to a click only where a glyph or a word happened to
                // be drawn: the gap between the name and the timestamp — most of the row — was dead.
                .contentShape(Rectangle())
                .onTapGesture {
                    // Selection follows the pointer as well as the keyboard, so Return afterwards
                    // acts on the row you last touched rather than on wherever the arrows were.
                    selectedRecentID = entry.id
                    Self.openProject(id: entry.id, onOpenProject: onOpenProject)
                }
                .contextMenu {
                    Button("Open") {
                        Self.openProject(id: entry.id, onOpenProject: onOpenProject)
                    }
                    Divider()
                    Button("Duplicate") {
                        Self.duplicateProject(id: entry.id, onDuplicateProject: onDuplicateProject)
                    }
                    Divider()
                    Button("Delete project\u{2026}", role: .destructive) {
                        viewState.beginDeleting(entry)
                    }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Arrow keys move the selection because the list has one; this is the other half of the
        // contract. A launcher you cannot open from the keyboard is a launcher you have to aim at.
        .onKeyPress(.return) { openSelectedRecent() }
        .onAppear {
            selectedRecentID = Self.validSelection(selectedRecentID, in: recentProjects)
        }
        // Deleting the selected project would otherwise leave the selection pointing at a row that
        // no longer exists, and Return would do nothing with no visible reason why.
        .onChange(of: recentProjects) { _, entries in
            selectedRecentID = Self.validSelection(selectedRecentID, in: entries)
        }
    }

    private func openSelectedRecent() -> KeyPress.Result {
        guard let selectedRecentID else { return .ignored }
        Self.openProject(id: selectedRecentID, onOpenProject: onOpenProject)
        return .handled
    }

    /// Keeps the selection on a row that exists: the current one if it survived, otherwise the top
    /// of the list, so the arrow keys always have somewhere to start.
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

// MARK: - Action Row

private struct ActionRow: View {
    let icon: String
    let title: String
    let help: String
    let identifier: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: DSSpacing.md) {
                // A point above `DSGlyph.controlProminent` (13), the ladder's ceiling — so this is
                // off the ladder rather than exempt from it, and `DSGlyph`'s own note names these
                // welcome-window action glyphs as the one site in that position. Left at 14 because
                // dropping it to the ceiling is a visual decision about the first screen a new user
                // sees, not a mechanical substitution: unlike every other glyph on the ladder these
                // stand in a padded action row rather than in a panel's chrome.
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(DSColors.accentText)
                    .frame(width: 20)

                Text(title)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelPrimary)

                Spacer()
            }
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                    .fill(isHovered ? DSColors.accentSubtle : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // The highlight used to snap on and off. Every other hover in the app eases, and the one
        // that does not is the one on the first screen.
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

// MARK: - Recent Project Row

private struct RecentProjectRow: View {
    let entry: RecentProjectEntry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image("MimicLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                // 7 is the same 0.2237 squircle the hero icon uses, at 32pt. Both are app-icon
                // masks rather than control corners, which is why neither is a token.
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(DSTypography.bodyMedium)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Was `Text(date, style: .relative)`, which is a live-updating timer: every row in
                // the list re-rendered once a second to move a number nobody was watching. This is
                // a formatted string, resolved once.
                Text("Last opened \(Self.relativeText(for: entry.lastOpenedAt))")
                    .font(DSTypography.caption)
                    // Not `labelTertiary`: at 36% alpha this was the only thing distinguishing two
                    // rows and you could barely read it.
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DSSpacing.sm)

            // The exact moment, in a column of its own. Two projects last opened "3 days ago" are
            // the same row until one says 09:41 and the other says 17:02 — and with five similar
            // names in the list that is the only thing left to tell them apart, since a project
            // here is a row in the store rather than a file with a path to show.
            //
            // Monospaced so the column reads as tabular data rather than as a second sentence; that
            // is what distinguishes it from the line to its left, not a fainter grey. Nothing a user
            // has to read is set at `labelTertiary`.
            Text(Self.stampText(for: entry.lastOpenedAt))
                .font(DSTypography.codeSmall)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                // `accentSubtle` (12%), the app's one hover fill, rather than a hand-rolled 15%.
                .fill(isHovered ? DSColors.accentSubtle : .clear)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
        .help(Self.fullStampText(for: entry.lastOpenedAt))
        // Paired deliberately: an identifier on a container overrides its descendants', so without
        // `.contain` the name and the timestamp inside this row would both report
        // "recentProject-<name>" and vanish as addressable text.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recentProject-\(entry.name)")
        .accessibilityLabel("\(entry.name), last opened \(Self.relativeText(for: entry.lastOpenedAt))")
    }

    /// "yesterday", "3 days ago" — the reading you want while scanning.
    static func relativeText(for date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Time for today, date otherwise — the convention Finder and Mail use for a date column, and
    /// the reason the column stays narrow enough to sit beside the name.
    static func stampText(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The unabbreviated version, for the tooltip.
    static func fullStampText(for date: Date) -> String {
        "Last opened \(date.formatted(date: .long, time: .shortened))"
    }
}
