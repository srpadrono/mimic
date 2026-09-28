import SwiftUI
import Domain
import DesignSystem

/// Welcome window: the app's identity and start actions on the left, projects on the right.
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
    let onRequestImport: (() -> Void)?
    let onRequestOpenExport: (() -> Void)?
    let onRequestSampleProject: (() -> Void)?

    @State private var viewState: ViewState
    /// The row the keyboard is on. Kept out of `ViewState`, which holds only modal state.
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
        onRequestRenameProject: @escaping (RecentProjectEntry) -> Void = { _ in },
        onRequestNewProject: @escaping () -> Void,
        onRequestImport: (() -> Void)? = nil,
        onRequestOpenExport: (() -> Void)? = nil,
        onRequestSampleProject: (() -> Void)? = nil
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
        onRequestImport: (() -> Void)? = nil,
        onRequestOpenExport: (() -> Void)? = nil,
        onRequestSampleProject: (() -> Void)? = nil,
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
        _viewState = State(initialValue: ViewState(deleteTarget: initialDeleteTarget))
    }

    public var body: some View {
        GeometryReader { geometry in
            let heroWidth = min(400, max(300, geometry.size.width * 0.45))
            // 112 at the design's 560pt height, smaller in a short window so the actions still fit.
            let iconSize = min(112, max(64, geometry.size.height * 0.2))

            HStack(spacing: 0) {
                leftColumn(iconSize: iconSize)
                    .frame(width: heroWidth)
                    .frame(maxHeight: .infinity)
                    .background(DSColors.content)

                DSDivider(axis: .vertical, identifier: "welcome.columns")

                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(DSColors.sheet)
            }
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
            // The title is a `String`, so the message carries the identifier.
            Text(ViewState.deleteMessage)
                .accessibilityIdentifier("welcome.deleteAlert.message")
        }
    }

    var currentViewState: ViewState {
        viewState
    }

    // MARK: - Left column

    private func leftColumn(iconSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: DSSpacing.xl)
            hero(iconSize: iconSize)
            actions
                .padding(.top, DSSpacing.xxl + DSSpacing.xs)
            Spacer(minLength: DSSpacing.xl)
        }
        .padding(.horizontal, DSSpacing.xxxl)
    }

    private func hero(iconSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image("MimicLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                // App-icon squircle, not a control corner, so it scales with the icon.
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.23, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
                // The title below says "Mimic"; VoiceOver should not read it twice.
                .accessibilityHidden(true)

            Text("Mimic")
                .font(DSTypography.largeTitle)
                .foregroundStyle(DSColors.labelPrimary)
                .padding(.top, DSSpacing.lg)
                .accessibilityIdentifier("welcomeHeroTitle")

            if let versionText {
                Text(versionText)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .padding(.top, DSSpacing.xs)
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
                WelcomeActionRow(
                    icon: "square.and.arrow.down",
                    title: "Import HAR or OpenAPI\u{2026}",
                    shortcut: nil,
                    help: "Create a project from a HAR file or an OpenAPI spec",
                    identifier: "welcome.import",
                    action: onRequestImport
                )
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

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            recentsHeader

            if recentProjects.isEmpty {
                emptyRecents
            } else {
                recentsList
            }
        }
        .padding(.top, DSSpacing.xxxl + DSSpacing.md)
    }

    /// "Projects" rather than "Recent projects": the list holds every stored project, ordered by
    /// recency. The count is left out when the list is empty.
    private var recentsHeader: some View {
        HStack(spacing: DSSpacing.xs) {
            Text("Projects")
                .font(DSTypography.captionSemibold)
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityAddTraits(.isHeader)
            if let recentCountSubtitle {
                Text(recentCountSubtitle)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelTertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.xl + DSSpacing.xs)
        .padding(.bottom, DSSpacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.recents.header")
    }

    private var recentCountSubtitle: String? {
        guard !recentProjects.isEmpty else { return nil }
        return "\(recentProjects.count)"
    }

    private var emptyRecents: some View {
        DSEmptyState(
            systemImage: "clock",
            heading: "No projects yet",
            message: "Create one to define mock endpoints and start a server.",
            identifier: "welcome.recents"
        )
    }

    private var recentsList: some View {
        List(recentProjects, selection: $selectedRecentID) { entry in
            RecentProjectRow(entry: entry)
                .listRowInsets(EdgeInsets(
                    top: DSSpacing.xxs / 2,
                    leading: DSSpacing.md,
                    bottom: DSSpacing.xxs / 2,
                    trailing: DSSpacing.md
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // The whole row is clickable, not only its text.
                .contentShape(Rectangle())
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
                        viewState.beginDeleting(entry)
                    }
                    .accessibilityIdentifier("welcome.recents.contextMenu.delete")
                }
        }
        .listStyle(.plain)
        // `.contain` before the identifier so naming the list does not rename the rows.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.recents.list")
        .scrollContentBackground(.hidden)
        // Arrow keys move the selection; Return opens it.
        .onKeyPress(.return) { openSelectedRecent() }
        .onAppear {
            selectedRecentID = Self.validSelection(selectedRecentID, in: recentProjects)
        }
        // Keep the selection on a row that still exists after a delete.
        .onChange(of: recentProjects) { _, entries in
            selectedRecentID = Self.validSelection(selectedRecentID, in: entries)
        }
    }

    private func openSelectedRecent() -> KeyPress.Result {
        guard let selectedRecentID else { return .ignored }
        Self.openProject(id: selectedRecentID, onOpenProject: onOpenProject)
        return .handled
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

/// A start action: an icon tile, a title and an optional shortcut hint.
private struct WelcomeActionRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    let help: String
    let identifier: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: DSGlyph.button, weight: .medium))
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
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: DSCornerRadius.card)
                    .fill(isHovered ? DSColors.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DSCornerRadius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

// MARK: - Recent project row

private struct RecentProjectRow: View {
    let entry: RecentProjectEntry
    @State private var isHovered = false
    /// `.increased` while the native list selection is drawn behind the row.
    @Environment(\.backgroundProminence) private var prominence

    private var isEmphasized: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Text(Self.initials(for: entry.name))
                .font(DSTypography.bodySemibold)
                .foregroundStyle(.white)
                .frame(width: DSControlHeight.prominent, height: DSControlHeight.prominent)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.segment)
                        .fill(Self.tileColor(for: entry.name))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(entry.name)
                    .font(DSTypography.bodySemibold)
                    .foregroundStyle(isEmphasized ? Color.white : DSColors.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("Last opened \(Self.timeText(for: entry.lastOpenedAt))")
                    .font(DSTypography.caption)
                    .foregroundStyle(isEmphasized ? Color.white.opacity(0.8) : DSColors.labelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DSSpacing.sm)

            Text(Self.stampText(for: entry.lastOpenedAt))
                .font(DSTypography.caption)
                .foregroundStyle(isEmphasized ? Color.white.opacity(0.8) : DSColors.labelTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(minHeight: DSRowHeight.recent + DSSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .fill(isHovered && !isEmphasized ? DSColors.hover : .clear)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
        .help(Self.fullStampText(for: entry.lastOpenedAt))
        // `.contain` keeps the name and dates addressable inside the row.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recentProject-\(entry.name)")
        .accessibilityLabel("\(entry.name), last opened \(Self.relativeText(for: entry.lastOpenedAt))")
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

    /// A stable colour per name. `hashValue` changes between launches, so this sums scalars instead.
    static func tileColor(for name: String) -> Color {
        let palette: [Color] = [
            DSColors.accent,
            DSColors.success,
            DSColors.Syntax.key,
            DSColors.warning,
            DSColors.Syntax.string,
            DSColors.error,
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }

    /// "yesterday", "3 days ago": used in the spoken label.
    static func relativeText(for date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// The time of day, shown under the name.
    static func timeText(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Today", "Yesterday", "Sep 21", or a numeric date in another year.
    static func stampText(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
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
