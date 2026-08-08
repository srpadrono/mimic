import SwiftUI
import Domain
import DesignSystem

/// The command palette (⌘⇧P) — every command the CLI can run, reachable from the keyboard.
///
/// The list is `CommandPalette` in Domain, which is a projection of `CommandCatalog`. Nothing here
/// knows the name of a single command, which is what makes "a command added later shows up here"
/// true rather than aspirational.
///
/// Modelled on Xcode's ⇧⌘O: a field you type into with the results directly beneath, arrow keys to
/// move, Return to run, Escape to leave. Deliberately *not* a sheet with OK/Cancel buttons — a
/// palette you have to dismiss with the mouse defeats the point of opening it from the keyboard.
struct CommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let onRun: (CommandPaletteEntry) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFieldFocused: Bool

    private var results: [CommandPaletteEntry] {
        CommandPalette.matches(query, in: entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            queryField
            Divider()
            resultList
            footer
        }
        .frame(width: 560, height: 420)
        .background(DSColors.surfaceElevated)
        .onAppear { isFieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandPalette")
    }

    // MARK: - Query

    private var queryField: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "command")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DSColors.labelSecondary)

            TextField("Run a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFieldFocused)
                .accessibilityIdentifier("commandPalette.query")
                // Return runs the highlighted row rather than the first, which is the whole point of
                // being able to arrow away from it.
                .onSubmit(runSelection)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: 44)
        // Arrow handling lives on the container, not the field. A `TextField` consumes arrow keys for
        // caret movement, so a handler attached to it never sees them — the palette would look
        // keyboard-driven and only respond to the mouse.
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        // Any change to the query invalidates the highlight: after narrowing the list, row 7 is a
        // different command than the one that was highlighted, and Return would run it.
        .onChange(of: query) { _, _ in selection = 0 }
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isSelected: index == selection)
                            .id(index)
                            .onTapGesture { selection = index; runSelection() }
                    }
                }
            }
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: DSAnimation.micro)) { proxy.scrollTo(new, anchor: .center) }
            }
            .overlay {
                if results.isEmpty {
                    DSEmptyState(
                        systemImage: "magnifyingglass",
                        heading: "No matching command",
                        message: "Try fewer letters, or the name the CLI uses.",
                        identifier: "commandPalette.empty"
                    )
                }
            }
        }
    }

    private func row(_ entry: CommandPaletteEntry, isSelected: Bool) -> some View {
        HStack(spacing: DSSpacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DSColors.accentText : DSColors.labelPrimary)
                Text(entry.descriptor.summary)
                    .font(DSTypography.Figure.small)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DSSpacing.sm)

            // The CLI spelling, always visible. The palette doubles as the discoverability surface for
            // the command line — someone who finds an operation here learns how to script it without
            // opening the docs.
            Text(entry.descriptor.cli)
                .font(DSTypography.codeBadge)
                .foregroundStyle(DSColors.labelTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DSColors.accentSubtle : Color.clear)
        .contentShape(Rectangle())
        // The highlighted row is announced as selected, so VoiceOver follows the arrow keys rather
        // than reading a static list.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title). \(entry.descriptor.summary)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("commandPalette.row.\(entry.id)")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DSSpacing.sm) {
            Text("\(results.count) command\(results.count == 1 ? "" : "s")")
                .foregroundStyle(DSColors.labelSecondary)

            Spacer()

            if let entry = highlighted, entry.requiresArguments {
                // Honest rather than broken: the model knows this command needs input, and there is no
                // argument form yet. Saying so — and showing the CLI spelling in the row — is better
                // than offering a Return that silently does nothing.
                Label("Needs arguments — run it from the CLI", systemImage: "terminal")
                    .foregroundStyle(DSColors.labelSecondary)
                    .accessibilityIdentifier("commandPalette.needsArguments")
            } else {
                Text("\u{21A9} to run \u{00B7} \u{2191}\u{2193} to move \u{00B7} esc to close")
                    .foregroundStyle(DSColors.labelTertiary)
            }
        }
        .font(DSTypography.Figure.small)
        .padding(.horizontal, DSSpacing.md)
        .frame(height: DSBarHeight.secondaryBar)
        .background(DSColors.band)
        .overlay(alignment: .top) {
            Rectangle().fill(DSColors.separator).frame(height: 0.5)
        }
    }

    // MARK: - Keyboard

    private var highlighted: CommandPaletteEntry? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    /// Moves the highlight, clamping rather than wrapping.
    ///
    /// Wrapping from the last row to the first is disorienting in a list you are scanning: holding
    /// the down arrow to reach the bottom would silently teleport you back to the top.
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    private func runSelection() {
        guard let entry = highlighted, !entry.requiresArguments else { return }
        onRun(entry)
        onDismiss()
    }
}
