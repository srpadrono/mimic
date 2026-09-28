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
/// - **Title left, controls right.** The title names a region you are already looking at; it is a
///   body-size label, not a headline competing with the content.
/// - **Controls are trailing and compact.** Anything that needs more room than that belongs in the
///   panel body, not in its chrome.
public struct DSPanelHeader<Accessory: View>: View {
    /// Shared across every panel so headers line up across the window. Matches the height of a
    /// small control plus its padding, which is the smallest a row with buttons can honestly be.
    ///
    /// Kept as an alias so `DSPanelHeader.height` still reads naturally from inside this file, but the
    /// number belongs to `DSBarHeight` — a bar that wants this tier should ask the ladder for it
    /// rather than reach through a generic view type for a constant.
    public static var height: CGFloat { DSBarHeight.paneHeader }

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
                // 13pt semibold at `labelPrimary`, above the 12pt tertiary subtitle, so the panel's
                // own name reads as the heading of its bar without competing with the content below.
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                // `.lineLimit(1)` with priority, not `.fixedSize()`. A rigid child in an `HStack` that
                // runs out of width is resolved by pushing the row's leading edge out of view, and the
                // request log's header hands its accessory several controls before this title gets a
                // say. Positive priority makes the title the *last* thing to yield without making the
                // row demand width the panel does not have.
                .lineLimit(1)
                // Tail, where the subtitle truncates in the middle: a subtitle is usually a path or a
                // count whose two ends both carry information, and a panel title is a word you can
                // still recognise from its start.
                .truncationMode(.tail)
                .layoutPriority(1)
                .accessibilityIdentifier("ds.panelheader.title.\(identifier)")

            if let subtitle {
                // The subtitle yields, the title does not. `.lineLimit(1)` and nothing else: with
                // `.fixedSize()` a long path pushed the title out of view, and `.layoutPriority(-1)`
                // lost to the `Spacer` every time so the subtitle vanished. Plain compression
                // truncates only when the row genuinely runs out of room.
                Text(subtitle)
                    .font(DSTypography.callout)
                    .monospacedDigit()
                    // `labelTertiary`: a count or path beside the title is supporting text, one step
                    // quieter than the secondary labels in the panel body.
                    .foregroundStyle(DSColors.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("ds.panelheader.subtitle.\(identifier)")
            }

            Spacer(minLength: DSSpacing.sm)

            if let accessory {
                accessory
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, DSSpacing.md)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.panelheader.\(identifier)")
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
/// but takes a real 24pt target and lights up under the pointer.
public struct DSPanelHeaderButton: View {
    private let systemImage: String
    private let help: String
    private let identifier: String
    private let role: ButtonRole?
    private let tint: Color?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(
        systemImage: String,
        help: String,
        identifier: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.identifier = identifier
        self.role = role
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                // `control`, the rung for a glyph that *is* the control. There is no title beside it
                // to carry the meaning, which is the whole reason this tier sits above the inline one.
                .font(.system(size: DSGlyph.control, weight: .regular))
                // `labelSecondary` at rest, not `labelTertiary`: at tertiary alpha the "add endpoint"
                // and "clear log" buttons were nearly invisible until the pointer found them.
                .foregroundStyle(tint ?? (isEnabled && isHovered ? DSColors.labelPrimary : DSColors.labelSecondary))
                // `DSControlHeight.regular`, the panel control size, so the target matches the
                // buttons and fields beside it.
                .frame(width: DSControlHeight.regular, height: DSControlHeight.regular)
                .background(
                    RoundedRectangle(cornerRadius: DSCornerRadius.field)
                        .fill(isEnabled && isHovered ? DSColors.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 && isEnabled }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { isHovered = false }
        }
        .animation(.easeOut(duration: DSAnimation.fast), value: isHovered)
        .help(help)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(help)
    }
}
