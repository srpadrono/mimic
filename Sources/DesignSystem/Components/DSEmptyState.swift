import SwiftUI

/// What a panel shows when it has nothing to show: an icon, a heading, a sentence, and — sometimes
/// — the one action that would fix it.
///
/// The hard part is that it has to work at both ends of the window. The sidebar is 220pt and the
/// inspector 280pt; the centre pane is whatever is left of a full-screen window. It used to be
/// written for the wide end only: `DSSpacing.xxl` on all four sides took 64pt of a 220pt panel
/// before a word was drawn, and an 80pt glow around a 36pt glyph then took another third of what
/// was left. Horizontal padding is now `lg` and the icon is sized for the narrow case, which the
/// wide case does not mind.
///
/// **The strings render exactly as given.** The heading arrives at XCUITest as an element's `value`
/// rather than its `label`, and the UI suite matches on the literal text, so a heading that
/// truncated instead of wrapping would not just look wrong — it would change what the suite reads.
/// **Do not add `.fixedSize(horizontal: false, vertical: true)` to these `Text`s.** It looks like the
/// way to say "wrap, never truncate", and it is not needed — a `Text` in a bounded width already
/// wraps, and nothing here sets `.lineLimit`. What it *does* do, combined with this view's
/// `.frame(maxHeight: .infinity)`, is make the whole view claim about a thousand points of height:
/// a `VStack` containing it then overflows its window, and the siblings above it are pushed off the
/// top. That is not theoretical — it put the journey editor's header, its behaviour section and its
/// run controls roughly 750pt above the top of the journeys window, where nothing could click them.
public struct DSEmptyState: View {
    /// Sized for a 220pt panel: with `lg` padding either side that leaves 188pt of content, and a
    /// 64pt circle reads as an illustration rather than as the panel's main event.
    private static let glowDiameter: CGFloat = 64
    private static let glyphSize: CGFloat = 26

    /// Below this the illustration is dropped, because it is the only part of this view that can be
    /// spared and the only part that was not being spared.
    ///
    /// The request log's default height is 220pt, less 30 for its header: 190. A full empty state
    /// needs about 187 — 64 of icon, 12 of spacing, 17 of heading, 12 more, two lines of message at
    /// 34, and 48 of vertical padding. Three points of slack, and the glow ring around the glyph
    /// spends them. The `VStack` resolved the overflow by squeezing the one child that can shrink,
    /// which is the sentence, and a `Text` given room for one line truncates rather than wraps: the
    /// drawer read "Start the server and send a request to see it appea…" while the identical
    /// component in the taller centre pane wrapped the same string cleanly.
    ///
    /// So the check is on the container, not on the text. An icon is an illustration; the sentence is
    /// the only thing here that tells you what to do.
    private static let minimumHeightForIcon: CGFloat = 200

    private let systemImage: String?
    private let heading: String
    private let message: String
    private let actionTitle: String?
    private let identifier: String
    private let isDefaultAction: Bool
    private let action: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    /// Zero means "not measured yet", which counts as roomy — the icon is what this view is usually
    /// for, so the first frame should not flash without it.
    @State private var availableHeight: CGFloat = 0

    /// - Parameter isDefaultAction: Makes the call-to-action answer Return.
    ///
    ///   Opt-in rather than automatic, because two empty states are routinely on screen at once — the
    ///   sidebar's and the centre pane's — and Return cannot belong to both. Set it where this view
    ///   *is* the primary action of a modal: the import sheets open on an empty state whose only
    ///   control is "Choose HAR file", and without this the sheet answered neither Return nor Tab, so
    ///   there was no way to import anything without a mouse.
    public init(
        systemImage: String? = nil,
        heading: String,
        message: String,
        actionTitle: String? = nil,
        identifier: String,
        isDefaultAction: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.heading = heading
        self.message = message
        self.actionTitle = actionTitle
        self.identifier = identifier
        self.isDefaultAction = isDefaultAction
        self.action = action
    }

    private var showsIcon: Bool {
        availableHeight == 0 || availableHeight >= Self.minimumHeightForIcon
    }

    public var body: some View {
        VStack(spacing: DSSpacing.md) {
            if let systemImage, showsIcon {
                icon(systemImage)
            }

            // Order matters, and getting it backwards is not a cosmetic mistake. `.fixedSize(vertical:)`
            // resolves a `Text`'s ideal height against whatever width is proposed *at that point in
            // the chain* — so capping the width afterwards is too late. With the cap last, a
            // measurement pass that proposes a narrow width made the sentence wrap to a height of
            // hundreds of points, and a `VStack` around it overflowed its window far enough to put
            // the journey editor's "Add step" button 755pt above the top of its own window.
            Text(heading)
                .font(DSTypography.heading)
                .foregroundStyle(DSColors.labelPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("ds.empty.\(identifier).heading")

            Text(message)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelSecondary)
                .multilineTextAlignment(.center)
                // Cap the measure first, then take the ideal height for that measure: wrap, never
                // truncate, and never run the full width of a maximised centre pane.
                .frame(maxWidth: 320)
                .accessibilityIdentifier("ds.empty.\(identifier).message")

            if let actionTitle, let action {
                DSButton(
                    actionTitle,
                    variant: .primary,
                    size: .medium,
                    identifier: "empty.\(identifier).cta",
                    action: action
                )
                .modifier(DefaultActionShortcut(isEnabled: isDefaultAction))
                // A beat more than the stack's own rhythm: the action is a different kind of thing
                // from the sentence explaining why it is offered.
                .padding(.top, DSSpacing.xs)
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        // `lg` rather than `xl` once the illustration is gone: without it the block is short enough
        // that 24pt above and below reads as the panel having been left half-empty on purpose.
        .padding(.vertical, showsIcon ? DSSpacing.xl : DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The container's height, not the content's. `.frame(maxHeight: .infinity)` above means this
        // view always takes whatever it is offered, so this reports exactly what there is to work in.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        // Reduce Motion keeps the cross-fade — which is the recommended substitute — and drops the
        // scale, which is the part that actually moves.
        .scaleEffect(reduceMotion ? 1.0 : (appeared ? 1.0 : 0.96))
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.easeOut(duration: DSAnimation.normal), value: appeared)
        .onAppear { appeared = true }
        // Paired deliberately. A bare identifier on a container makes every descendant report the
        // container's name instead of its own, which left `…heading`, `…message` and the call to
        // action — a real button — with no addressable identity of their own.
        .accessibilityIdentifier("ds.empty.\(identifier)")
        .accessibilityElement(children: .contain)
    }

    /// Decoration, and hidden from the accessibility tree accordingly — the heading beneath it says
    /// the same thing in words.
    ///
    /// The glyph used to be 36pt at `.light` weight in `labelTertiary`, which is 36% alpha: a large,
    /// thin, very faint shape that read as a smudge rather than as a symbol. Smaller, at a normal
    /// weight, in `labelSecondary`, it is legible — and it is the fastest way to tell which empty
    /// state you are looking at.
    private func icon(_ systemImage: String) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [DSColors.accent.opacity(0.10), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: Self.glowDiameter / 2
                    )
                )
                .frame(width: Self.glowDiameter, height: Self.glowDiameter)

            Image(systemName: systemImage)
                .font(.system(size: Self.glyphSize, weight: .regular))
                .foregroundStyle(DSColors.labelSecondary)
        }
        .accessibilityHidden(true)
    }
}

/// Applies `.keyboardShortcut(.defaultAction)` only when asked.
///
/// A conditional modifier rather than `if isDefaultAction { … } else { … }` around the button: the
/// two branches would be different view types, so SwiftUI would tear down and rebuild the button
/// whenever the flag changed, losing its hover state and any in-flight animation. This keeps one
/// identity and toggles the shortcut on it.
private struct DefaultActionShortcut: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.keyboardShortcut(isEnabled ? .defaultAction : nil)
    }
}
