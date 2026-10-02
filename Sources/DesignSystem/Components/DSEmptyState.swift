import SwiftUI

/// An action an empty state offers. The first primary action answers Return when the state asks it to.
public struct DSEmptyStateAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let isPrimary: Bool
    public let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, isPrimary: Bool = false,
                identifier: String, action: @escaping () -> Void) {
        self.id = identifier
        self.title = title
        self.systemImage = systemImage
        self.isPrimary = isPrimary
        self.action = action
    }
}

/// Says what goes here and offers the next step.
public struct DSEmptyState: View {
    public enum Prominence {
        /// The centre of the window: a 20pt title.
        case large
        /// A pane or panel: a 13pt title.
        case regular
        /// A sidebar or narrow strip: quiet text, no symbol.
        case compact
    }

    private let systemImage: String?
    private let heading: String
    private let message: String
    private let actions: [DSEmptyStateAction]
    private let identifier: String
    private let isDefaultAction: Bool
    private let prominence: Prominence

    public init(
        systemImage: String? = nil,
        heading: String,
        message: String,
        actions: [DSEmptyStateAction],
        prominence: Prominence = .regular,
        identifier: String,
        isDefaultAction: Bool = false
    ) {
        self.systemImage = systemImage
        self.heading = heading
        self.message = message
        self.actions = actions
        self.prominence = prominence
        self.identifier = identifier
        self.isDefaultAction = isDefaultAction
    }

    /// One primary action, the shape most panes need.
    public init(
        systemImage: String? = nil,
        heading: String,
        message: String,
        actionTitle: String? = nil,
        prominence: Prominence = .regular,
        identifier: String,
        isDefaultAction: Bool = false,
        action: (() -> Void)? = nil
    ) {
        var actions: [DSEmptyStateAction] = []
        if let actionTitle, let action {
            actions.append(DSEmptyStateAction(actionTitle, isPrimary: true, identifier: "empty.\(identifier).cta",
                                              action: action))
        }
        self.init(systemImage: systemImage, heading: heading, message: message, actions: actions,
                  prominence: prominence, identifier: identifier, isDefaultAction: isDefaultAction)
    }

    public var body: some View {
        VStack(spacing: prominence == .compact ? 6 : DSSpacing.sm) {
            if let systemImage, prominence != .compact {
                Image(systemName: systemImage)
                    .font(.system(size: prominence == .large ? DSGlyph.illustration + 4 : DSGlyph.illustration,
                                  weight: .light))
                    .foregroundStyle(DSColors.labelTertiary)
                    .padding(.bottom, DSSpacing.xs)
                    .accessibilityHidden(true)
            }

            Text(heading)
                .font(headingFont)
                .foregroundStyle(prominence == .compact ? DSColors.labelSecondary : DSColors.labelPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("ds.empty.\(identifier).heading")

            Text(message)
                .font(messageFont)
                // The boards set empty-state paragraphs on 17 pt lines at 12 pt and 18 pt at 13 pt.
                .lineSpacing(DSTypography.Leading.tight)
                .foregroundStyle(prominence == .compact ? DSColors.labelTertiary : DSColors.labelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: prominence == .large ? 460 : DSLayout.emptyStateTextWidth)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ds.empty.\(identifier).message")

            if !actions.isEmpty {
                HStack(spacing: DSSpacing.sm) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                        DSButton(item.title, systemImage: item.systemImage,
                                 variant: item.isPrimary ? .primary : .secondary,
                                 size: prominence == .large ? .large : .medium,
                                 identifier: item.id, action: item.action)
                            .modifier(DefaultActionShortcut(isEnabled: isDefaultAction && index == 0))
                    }
                }
                .padding(.top, DSSpacing.xs)
            }
        }
        .padding(.horizontal, prominence == .compact ? DSSpacing.xxl : DSSpacing.lg)
        .padding(.vertical, DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.empty.\(identifier)")
    }

    private var headingFont: Font {
        switch prominence {
        case .large: DSTypography.title
        case .regular: DSTypography.bodySemibold
        case .compact: DSTypography.callout
        }
    }

    private var messageFont: Font {
        switch prominence {
        case .large: DSTypography.body
        case .regular: DSTypography.callout
        case .compact: DSTypography.caption
        }
    }
}

private struct DefaultActionShortcut: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.keyboardShortcut(isEnabled ? .defaultAction : nil)
    }
}
