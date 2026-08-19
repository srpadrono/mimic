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
public struct DSPanelHeader<Accessory: View>: View {
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
    private let accessory: Accessory?

    public init(
        _ title: String,
        subtitle: String? = nil,
        identifier: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(title)
                // `controlLabel` at `labelPrimary`, where both of these used to be
                // `DSTypography.caption` at `labelSecondary` — the *same font and the same colour as
                // the count beside it*. A panel's own name was the quietest text in its own bar, and
                // "Scenarios" and "/account-summary" arrived with equal weight, so nothing in the row
                // said which was the heading. 12pt semibold against 10pt medium is the smallest
                // change that makes the title read as the title.
                .font(DSTypography.controlLabel)
                .foregroundStyle(DSColors.labelPrimary)
                // `.lineLimit(1)` with priority, not `.fixedSize()`.
                //
                // The subtitle below explains how `.fixedSize()` produced "narios" instead of
                // "Scenarios" — and then the fix was applied to the subtitle while the modifier stayed
                // on the title, which is the string the original defect was about. The mechanism never
                // went away: a rigid child in an `HStack` that runs out of width is resolved by
                // pushing the row's leading edge out of view, and the request log's header hands its
                // accessory a picker, a toggle, a 120pt filter well and a button before this title
                // gets a say. The subtitle merely absorbs the slack first, so it takes a narrow
                // window rather than a long word to reach it.
                //
                // Positive priority is the half of the subtitle's lesson that works: it makes the
                // title the *last* thing to yield without ever making the row demand width the panel
                // does not have. A negative priority on the subtitle was the version that failed.
                .lineLimit(1)
                // Tail, where the subtitle truncates in the middle: a subtitle is usually a path or a
                // count whose two ends both carry information, and a panel title is a word you can
                // still recognise from its start.
                .truncationMode(.tail)
                .layoutPriority(1)
                .accessibilityIdentifier("ds.panelheader.title.\(identifier)")

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
                    .font(DSTypography.caption)
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
        .background(DSColors.secondary)
        .overlay(alignment: .bottom) {
            Rectangle()
                // `separator`, not `panelSeparator`. One rule for the whole window: a horizontal
                // bar closes at 12%, and `panelSeparator` is reserved for the seam *between*
                // panels. Bar bottoms were split 14% / 12% depending on whether the author reached
                // for an overlay or for `DSDivider`, and the split tracked nothing — the request
                // detail's identity row closed lighter than a section header inside it.
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
        .accessibilityIdentifier("ds.panelheader.\(identifier)")
        .accessibilityElement(children: .contain)
    }
}

extension DSPanelHeader where Accessory == EmptyView {
    public init(_ title: String, subtitle: String? = nil, identifier: String) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
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
                // `control`, the rung for a glyph that *is* the control. There is no title beside it
                // to carry the meaning, which is the whole reason this tier sits above the inline one.
                .font(.system(size: DSGlyph.control, weight: .medium))
                // `labelSecondary` at rest, not `labelTertiary`. At 36% alpha the "add endpoint" and
                // "clear log" buttons were nearly invisible until the pointer found them — a control
                // you have to hunt for is one most people never discover. Same correction
                // `DSTabStrip` made for its unselected tabs.
                .foregroundStyle(isHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
                // `field`, the rung a single prominent control in a header stands on. This was a bare
                // `22` in the module that declares the ladder, which is the one place a literal has no
                // excuse: `DSTabStrip` wrote the same number for the same target a file away.
                .frame(width: DSControlHeight.field, height: DSControlHeight.field)
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
