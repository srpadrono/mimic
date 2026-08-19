import SwiftUI

/// Typography role tokens — SF Pro + SF Mono.
///
/// The scale is role-named rather than size-named on purpose: a view asks for the job the text is
/// doing, so changing what "a column label" measures is one edit here rather than a search for
/// `.system(size: 10.5)` across forty files.
///
/// **Half-point sizes are deliberate and are not rounding errors.** The redesign specifies 9.5,
/// 10.5, 11.5, 12.5 and 13.5, and they were kept rather than snapped to the nearest whole point
/// because the gaps they sit in are the ones that carry meaning. 11 and 12 are both already spoken
/// for — `label` and `code` — so a "slightly larger than a caption, slightly smaller than body"
/// role has nowhere else to go, and rounding it collapses two distinct tiers into one. On a Retina
/// display a half point is a whole pixel, so these are not sub-pixel wishes.
public enum DSTypography {
    // MARK: - Body scale

    /// SF Pro 13px regular — default body text
    public static let body: Font = .system(size: 13, weight: .regular)
    /// SF Pro 13px medium — emphasized body without bold
    public static let bodyMedium: Font = .system(size: 13, weight: .medium)
    /// SF Pro 13px semibold — strong emphasis, active states
    public static let bodyBold: Font = .system(size: 13, weight: .semibold)

    // MARK: - Small scale

    /// SF Pro 11px regular — labels, captions
    public static let label: Font = .system(size: 11, weight: .regular)
    /// SF Pro 10px medium — timestamps, footnotes, tertiary labels
    public static let caption: Font = .system(size: 10, weight: .medium)

    /// SF Pro 10.5px regular — a column header, a provenance line, a panel's own count.
    ///
    /// The tier that exists because ``caption`` is not allowed to do this job. `caption` is 10pt and
    /// is paired with `labelTertiary` throughout, which is 36% alpha and measures 2.48:1 — right for
    /// a timestamp, wrong for text a user has to read to operate the window. Anything at this size
    /// sits at `labelSecondary` or above.
    public static let metaSmall: Font = .system(size: 10.5, weight: .regular)

    /// SF Pro 11.5px regular — secondary meta inside a dense row: the scenario name, the endpoint
    /// name beside a path, a template card's description.
    public static let meta: Font = .system(size: 11.5, weight: .regular)

    /// SF Pro 11.5px semibold — the same tier when it carries state rather than description, e.g.
    /// the unmatched toggle's count or a journey's "Active".
    public static let metaBold: Font = .system(size: 11.5, weight: .semibold)

    /// SF Pro 12px semibold — a panel header's own title, a section label, a selected tab.
    ///
    /// Semibold at 12 rather than regular at 13: this is a label for a region you are already
    /// looking at, so it has to be identifiable without being loud, and weight reads as
    /// "this names something" where size reads as "this is important".
    public static let controlLabel: Font = .system(size: 12, weight: .semibold)

    /// SF Pro 12px regular — an unselected tab, an inactive mode in the inspector's rail.
    public static let controlLabelQuiet: Font = .system(size: 12, weight: .regular)

    // MARK: - Heading scale

    /// SF Pro 14px medium — sub-section headings, panel titles
    public static let subheading: Font = .system(size: 14, weight: .medium)
    /// SF Pro 16px semibold — section headings
    public static let heading: Font = .system(size: 16, weight: .semibold)

    /// SF Pro 19px semibold — an empty state that teaches rather than apologises.
    ///
    /// One tier, used once: the journeys gallery's headline. It sits between ``heading`` and
    /// ``title`` because it is a sentence inside a pane rather than a sheet's name, and at 20 it
    /// competed with the window title.
    public static let headline: Font = .system(size: 19, weight: .semibold)

    /// SF Pro 20px semibold — sheet titles, dialog headings
    public static let title: Font = .system(size: 20, weight: .semibold)
    /// SF Pro 28px bold — display / hero text
    public static let display: Font = .system(size: 28, weight: .bold)

    // MARK: - Code scale

    /// SF Mono 9.5px semibold — a method badge's three characters.
    ///
    /// The smallest type in the window, and it is allowed to be because it is three uppercase
    /// letters on a tinted pill with generous tracking — not prose. Nothing else may use it.
    public static let codeBadge: Font = .system(size: 9.5, weight: .semibold, design: .monospaced)

    /// SF Mono 11px regular — compact code in sidebar rows, log timestamps
    public static let codeSmall: Font = .system(size: 11, weight: .regular, design: .monospaced)
    /// SF Mono 12px regular — JSON, paths, ports, code
    public static let code: Font = .system(size: 12, weight: .regular, design: .monospaced)
    /// SF Mono 12px medium — method badges, emphasized code
    public static let codeBold: Font = .system(size: 12, weight: .medium, design: .monospaced)

    /// SF Mono 12.5px regular — a route in a dense list: the navigator's rows and the request log's.
    ///
    /// The width arithmetic in `docs/redesign/decisions.md` is taken at this size. Changing it
    /// changes how many characters of `/api/v1/orders/{id}` survive in a 300pt navigator, so it is
    /// not a free knob.
    public static let codePath: Font = .system(size: 12.5, weight: .regular, design: .monospaced)

    /// SF Mono 13px regular — prominent code like base URL
    public static let codeLarge: Font = .system(size: 13, weight: .regular, design: .monospaced)

    /// SF Mono 13.5px semibold — the route in the editor's own header, where it is the identity of
    /// the thing being edited rather than one row among many.
    public static let codeHeading: Font = .system(size: 13.5, weight: .semibold, design: .monospaced)

    // MARK: - Figures

    /// Numbers that sit in a column, or that tick while you watch them.
    ///
    /// `.monospacedDigit()` and not merely a monospaced *design*: proportional digits are why a
    /// counter appears to shuffle as it climbs from 9 to 10, and why a column of status codes does
    /// not line up on its hundreds place. Every figure the redesign aligns — the log's status and
    /// time columns, the inspector's Sizes block, the Overview card — takes one of these.
    public enum Figure {
        /// SF Mono 11px — a timestamp or a small count in a table row.
        public static let small: Font = DSTypography.codeSmall.monospacedDigit()
        /// SF Mono 11.5px semibold — a status code as coloured text in the log.
        public static let status: Font = Font
            .system(size: 11.5, weight: .semibold, design: .monospaced)
            .monospacedDigit()
        /// SF Mono 14px semibold — the status code in the editor's response row.
        public static let statusLarge: Font = Font
            .system(size: 14, weight: .semibold, design: .monospaced)
            .monospacedDigit()
        /// SF Mono 17px semibold — the Overview card's headline figures.
        public static let display: Font = Font
            .system(size: 17, weight: .semibold, design: .monospaced)
            .monospacedDigit()
    }

    // MARK: - Line height

    /// Extra leading for the few places the redesign specifies a ratio rather than a single line.
    ///
    /// SwiftUI has no line-height on `Font`, so these are `.lineSpacing()` values — the *gap*
    /// between lines, not the total. Each is the design's ratio converted for the size it is used
    /// at: spacing = size × (ratio − 1), rounded to a whole point because a fractional gap between
    /// wrapped lines is not something anyone can see.
    public enum Leading {
        /// 11.5pt at 1.45 — a template card's description, an explanatory card in the inspector.
        public static let meta: CGFloat = 5
        /// 13pt at 1.55 — the paragraph under an empty state's headline.
        public static let body: CGFloat = 7
        /// 12pt at 17pt line box — the JSON body editor, matching its gutter's line numbers.
        public static let code: CGFloat = 5
    }
}
