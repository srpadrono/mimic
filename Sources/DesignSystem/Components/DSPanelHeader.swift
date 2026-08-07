import SwiftUI

/// The single bar that identifies a panel and carries its controls.
///
/// Every panel in the workspace — sidebar, request log, inspector — wears this, which is the whole
/// point. Before it, each panel invented its own chrome: the log put a title inline with a method
/// picker and a search field on one row and column headers on another, the inspector had a different
/// header, and the sidebar had none at all. Nothing lined up horizontally, and the log spent about a
/// quarter of its height on chrome before showing a single request.
///
/// So the rules are deliberately rigid:
///
/// - **One row, one fixed height.** `DSPanelHeader.height` is the same everywhere, so panel headers
///   align across the window no matter which panel you look at.
/// - **Title left, controls right.** The title is quiet — this is a label for a region you are
///   already looking at, not a headline competing with the content.
/// - **Controls are trailing and compact.** Anything that needs more room than that belongs in the
///   panel body, not in its chrome.
public struct DSPanelHeader<Leading: View, Accessory: View>: View {
    /// Shared across every panel so headers line up across the window. Matches the height of a
    /// small control plus its padding, which is the smallest a row with buttons can honestly be.
    ///
    /// Kept as an alias so `DSPanelHeader.height` still reads naturally from inside this file, but the
    /// number belongs to `DSBarHeight` — a bar that wants this tier should ask the ladder for it
    /// rather than reach through a generic view type for a constant.
    public static var height: CGFloat { DSBarHeight.panelHeader }

    private let title: String
    private let subtitle: String?
    private let identifier: String
    private let host: DSSurfaceHost
    private let leading: Leading?
    private let accessory: Accessory?

    public init(
        _ title: String,
        subtitle: String? = nil,
        identifier: String,
        host: DSSurfaceHost = .content,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.host = host
        self.leading = leading()
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            // The leading slot: a tab strip, a breadcrumb, a mode rail. It comes *before* the title
            // rather than replacing it, because a panel that has both — the request log has a title
            // and a filter row — should not have to choose which one is "the header".
            //
            // Not wrapped in its own identifier. Naming a container here would rename every control
            // inside it, which is the flattening AGENTS.md rule 8 documents; the slot's contents keep
            // their own names and their own labels.
            if let leading {
                leading
            }

            if !title.isEmpty {
                Text(title)
                    // 12pt semibold, up from 10pt medium. A panel's own name was the quietest text in
                    // its own bar — quieter than the count beside it — which is why three panels grew
                    // their own louder title rows before this component existed.
                    .font(DSTypography.controlLabel)
                    .foregroundStyle(DSColors.labelPrimary)
                    .fixedSize()
                    .accessibilityIdentifier("ds.panelheader.title.\(identifier)")
            }

            if let subtitle {
                // The subtitle yields, the title does not. With `.fixedSize()` here too, a long one
                // — an endpoint path, say — made the row demand more width than the panel had, and
                // the `HStack` resolved that by pushing its leading edge out of view: the inspector
                // header read "narios" instead of "Scenarios", and the trailing controls went with
                // it. A subtitle is the one part of this row that can afford to lose characters.
                // `.lineLimit(1)` and nothing else. `.layoutPriority(-1)` looked like the way to say
                // "yield first", but a `Spacer` claims the slack at default priority, so a negative
                // one meant the subtitle lost every time and disappeared entirely — the request log
                // header stopped reporting its count. Plain compression truncates only when the row
                // genuinely runs out of room, which is the behaviour wanted.
                Text(subtitle)
                    // SF Mono with tabular figures: this slot is a count, and a count that shifts
                    // width as it climbs from 9 to 10 makes the whole row twitch while traffic runs.
                    .font(DSTypography.Figure.small)
                    // `labelSecondary`, not tertiary. This slot is where a panel states its count —
                    // "5 requests", "3 scenarios" — and `DSTabStrip` justifies its number-less badge
                    // on exactly that. It is text a user reads, and 36% alpha measures 2.48:1 on
                    // `secondary` in light mode, against the 4.5:1 this palette holds itself to.
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("ds.panelheader.subtitle.\(identifier)")
            }

            Spacer(minLength: DSSpacing.sm)

            if let accessory {
                accessory
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: Self.height)
        // No fill at all on a sidebar host — see `DSSurfaceHost`. Over `surfaceSidebar` this bar's
        // colour measures ΔL* 0.30, which is not a quiet fill, it is no fill drawn expensively. The
        // rule below does the separating there, as it does in an `NSTableHeaderView`.
        .background(host.chromeFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                // `separator`, not `panelSeparator`. One rule for the whole window: a horizontal
                // bar closes at 12%, and `panelSeparator` is reserved for the seam *between*
                // panels. Bar bottoms were split 14% / 12% depending on whether the author reached
                // for an overlay or for `DSDivider`, and the split tracked nothing — the request
                // detail's identity row closed lighter than a section header inside it.
                .fill(DSColors.separator)
                .frame(height: 0.5)
        }
        .accessibilityIdentifier("ds.panelheader.\(identifier)")
        .accessibilityElement(children: .contain)
    }
}

extension DSPanelHeader where Leading == EmptyView {
    /// A header with trailing controls and no leading accessory — the common shape.
    public init(
        _ title: String,
        subtitle: String? = nil,
        identifier: String,
        host: DSSurfaceHost = .content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.host = host
        self.leading = nil
        self.accessory = accessory()
    }
}

/// There is deliberately no "leading accessory, no trailing controls" convenience. Both slots take a
/// single `@ViewBuilder` closure, so a trailing-closure call site could not tell the two overloads
/// apart — `DSPanelHeader("x", identifier: "y") { … }` is ambiguous. A header that wants only a
/// leading slot passes `accessory: { EmptyView() }` explicitly, which is one extra line at the two
/// call sites that need it and no guessing at any of the others.
extension DSPanelHeader where Leading == EmptyView, Accessory == EmptyView {
    public init(
        _ title: String,
        subtitle: String? = nil,
        identifier: String,
        host: DSSurfaceHost = .content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.host = host
        self.leading = nil
        self.accessory = nil
    }
}

// MARK: - Header controls

/// A compact icon button sized for a `DSPanelHeader`.
///
/// Panel headers were using bare `Image`s in `.plain` buttons, which gave a ~11pt hit target and no
/// hover feedback — fine to look at, awkward to actually hit. This keeps the same quiet appearance
/// but takes a real 22pt target and lights up under the pointer.
public struct DSPanelHeaderButton: View {
    private let systemImage: String
    private let help: String
    private let identifier: String
    private let role: ButtonRole?
    private let action: () -> Void

    @State private var isHovered = false

    public init(
        systemImage: String,
        help: String,
        identifier: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.identifier = identifier
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                // `labelSecondary` at rest, not `labelTertiary`. At 36% alpha the "add endpoint" and
                // "clear log" buttons were nearly invisible until the pointer found them — a control
                // you have to hunt for is one most people never discover. Same correction
                // `DSTabStrip` made for its unselected tabs.
                .foregroundStyle(isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                        .fill(isHovered ? DSColors.accentSubtle : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(help)
    }
}
