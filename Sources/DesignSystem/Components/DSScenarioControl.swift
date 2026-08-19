import SwiftUI

/// The active scenario, in the editor's own title row, permanently.
///
/// This is the fix for "scenario switching is invisible". Before it, an endpoint's active scenario
/// was stated in two places you had to already be looking at — a crumb in a jump bar that has since
/// been deleted, and a list in the inspector that is only one of three modes that panel shows. The
/// thing an endpoint *currently answers with* was not on screen while you edited the response.
///
/// So it lives beside the path, it names the scenario, it shows what that scenario returns, and it is
/// the control that changes it.
public struct DSScenarioControl: View {
    /// One scenario as this control needs to see it — no Domain dependency, so DesignSystem stays a
    /// leaf and a preview can build one from literals.
    public struct Option: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var statusCode: Int

        public init(id: UUID, name: String, statusCode: Int) {
            self.id = id
            self.name = name
            self.statusCode = statusCode
        }
    }

    private let options: [Option]
    private let activeID: UUID?
    private let identifier: String
    private let onSelect: (UUID) -> Void
    private let onCreate: (() -> Void)?

    @State private var isHovered = false

    public init(
        options: [Option],
        activeID: UUID?,
        identifier: String = "editor.scenarioControl",
        onSelect: @escaping (UUID) -> Void,
        onCreate: (() -> Void)? = nil
    ) {
        self.options = options
        self.activeID = activeID
        self.identifier = identifier
        self.onSelect = onSelect
        self.onCreate = onCreate
    }

    private var active: Option? {
        options.first { $0.id == activeID }
    }

    public var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    // A checkmark, not a tint — the current choice has to survive Differentiate
                    // Without Color, and it is the same mark the scenario list in the inspector draws.
                    if option.id == activeID {
                        Label("\(option.name) — \(option.statusCode)", systemImage: "checkmark")
                    } else {
                        Text("\(option.name) — \(option.statusCode)")
                    }
                }
                .accessibilityIdentifier("\(identifier).option.\(option.id.uuidString)")
                .accessibilityLabel(option.id == activeID ? "\(option.name), selected" : option.name)
            }

            if let onCreate {
                Divider()
                Button("New scenario\u{2026}", action: onCreate)
                    .accessibilityIdentifier("\(identifier).newScenario")
                    .accessibilityLabel("New scenario")
            }
        } label: {
            label
        }
        // `.button` + `.plain`, the pairing `DSFilterField.ScopeMenu` documents at length: the label
        // below draws every pixel of this control, so the button style must contribute none. A
        // borderless *menu* becomes an NSPopUpButton, which draws its own indicator ahead of the
        // label and ignores `.menuIndicator(.hidden)`.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(active.map { "Active scenario: \($0.name)" } ?? "No active scenario")
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Active scenario")
        .accessibilityValue(active.map { "\($0.name), returns \($0.statusCode)" } ?? "None")
    }

    private var label: some View {
        HStack(spacing: DSSpacing.xs) {
            Text("Scenario")
                .font(DSTypography.metaSmall)
                .foregroundStyle(DSColors.labelSecondary)

            if let active {
                Text(active.name)
                    .font(DSTypography.metaBold)
                    .foregroundStyle(DSColors.accentText)
                    // The one string here that can grow, so it is the one that yields. No
                    // `.fixedSize()`: this control sits in an `HStack` beside a path that is already
                    // competing for the row, and a fixed-size label makes the row demand more width
                    // than the header has — which pushes the *leading* edge out of view.
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(active.statusCode)")
                    .font(DSTypography.Figure.status)
                    // The *deep* status colour. On this control's `accent @ 11%` fill the plain hues
                    // measure 4.10:1 for a 2xx and 4.41 for a 5xx in light — all below the floor. The
                    // handoff specifies "in the status colour", which is the failing version.
                    .foregroundStyle(DSColors.httpStatusColor(for: active.statusCode))
            } else {
                Text("None")
                    .font(DSTypography.metaBold)
                    .foregroundStyle(DSColors.labelSecondary)
            }

            Image(systemName: "chevron.up.chevron.down")
                // 8pt, the floor. The handoff asks for 6.5 here; below 8 this stops being an
                // affordance and becomes a smudge, which is the rule the filter field's scope
                // indicator already holds.
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.smPlus)
                .fill(DSColors.accent.opacity(isHovered ? 0.16 : 0.11))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.smPlus)
                .stroke(DSColors.accent.opacity(0.27), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}
