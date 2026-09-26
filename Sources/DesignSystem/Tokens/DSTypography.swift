import SwiftUI

/// Typography role tokens — SF Pro + SF Mono.
///
/// Operational text begins at 13pt. Smaller roles are reserved for supporting metadata so the
/// selected item, controls, and inspector values remain legible across narrow and wide layouts.
public enum DSTypography {
    // MARK: - Body scale

    /// 14pt — ordinary reading and editable values.
    public static let body: Font = .system(size: 14, weight: .regular)
    public static let bodyMedium: Font = .system(size: 14, weight: .medium)
    public static let bodyBold: Font = .system(size: 14, weight: .semibold)

    // MARK: - Small scale

    /// 13pt — operational labels, controls, and inspector values.
    public static let label: Font = .system(size: 13, weight: .regular)
    public static let labelMedium: Font = .system(size: 13, weight: .medium)
    /// 11pt — timestamps and nonessential annotations only.
    public static let caption: Font = .system(size: 11, weight: .medium)

    /// 11.5pt — compact column headers and provenance.
    public static let metaSmall: Font = .system(size: 11.5, weight: .regular)

    /// 12pt — secondary information inside a dense row.
    public static let meta: Font = .system(size: 12, weight: .regular)

    /// 12pt semibold — compact state information.
    public static let metaBold: Font = .system(size: 12, weight: .semibold)

    /// 13pt semibold — panel and section titles, selected tabs.
    public static let controlLabel: Font = .system(size: 13, weight: .semibold)

    /// 13pt regular — unselected tabs and inactive modes.
    public static let controlLabelQuiet: Font = .system(size: 13, weight: .regular)

    // MARK: - Heading scale

    /// 15pt medium — subsection headings.
    public static let subheading: Font = .system(size: 15, weight: .medium)
    /// 18pt semibold — selected content and section headings.
    public static let heading: Font = .system(size: 18, weight: .semibold)

    /// 20pt semibold — an instructional empty-state headline.
    public static let headline: Font = .system(size: 20, weight: .semibold)

    /// 21pt semibold — sheet titles and dialog headings.
    public static let title: Font = .system(size: 21, weight: .semibold)
    /// 28pt bold — display / hero text.
    public static let display: Font = .system(size: 28, weight: .bold)

    // MARK: - Code scale

    /// 10.5pt semibold — the smallest method badge, never prose.
    ///
    /// The smallest type in the window, and it is allowed to be because it is three uppercase
    /// letters on a tinted pill with generous tracking — not prose. Nothing else may use it.
    public static let codeBadge: Font = .system(size: 10.5, weight: .semibold, design: .monospaced)
    /// 11.5pt semibold — compact HTTP method badges.
    public static let codeBadgeCompact: Font = .system(size: 11.5, weight: .semibold, design: .monospaced)
    /// 12.5pt semibold — method badges beside editor routes.
    public static let codeBadgeStandard: Font = .system(size: 12.5, weight: .semibold, design: .monospaced)

    /// 12pt regular — compact code and log timestamps.
    public static let codeSmall: Font = .system(size: 12, weight: .regular, design: .monospaced)
    /// 13pt regular — JSON, paths, ports, and code.
    public static let code: Font = .system(size: 13, weight: .regular, design: .monospaced)
    /// 13pt medium — emphasized code.
    public static let codeBold: Font = .system(size: 13, weight: .medium, design: .monospaced)

    /// 13pt regular — a route in the navigator or request log.
    ///
    /// Keep route labels readable in the narrow navigator when adjusting this size.
    public static let codePath: Font = .system(size: 13, weight: .regular, design: .monospaced)

    /// 14pt regular — prominent code such as a base URL.
    public static let codeLarge: Font = .system(size: 14, weight: .regular, design: .monospaced)

    /// 15pt semibold — the route in the editor's own header, where it is the identity of
    /// the thing being edited rather than one row among many.
    public static let codeHeading: Font = .system(size: 15, weight: .semibold, design: .monospaced)

    // MARK: - Figures

    /// Numbers that sit in a column, or that tick while you watch them.
    ///
    /// `.monospacedDigit()` and not merely a monospaced *design*: proportional digits are why a
    /// counter appears to shuffle as it climbs from 9 to 10, and why a column of status codes does
    /// not line up on its hundreds place. Every figure the redesign aligns — the log's status and
    /// time columns, the inspector's Sizes block, the Overview card — takes one of these.
    public enum Figure {
        /// 12pt — a timestamp or a small count in a table row.
        public static let small: Font = DSTypography.codeSmall.monospacedDigit()
        /// 12.5pt semibold — a status code as coloured text in the log, and the base URL in
        /// the toolbar's status well.
        ///
        /// The well is the second consumer and it is the one this rung's `.monospacedDigit()` was
        /// written for: a port is four or five digits that change with every run, and the well sits
        /// between two other clusters in a toolbar, so proportional digits move its neighbours every
        /// time the server comes up on a different port.
        public static let status: Font = Font
            .system(size: 12.5, weight: .semibold, design: .monospaced)
            .monospacedDigit()
        /// 15pt semibold — the status code in the editor's response row.
        public static let statusLarge: Font = Font
            .system(size: 15, weight: .semibold, design: .monospaced)
            .monospacedDigit()
        /// 18pt semibold — the Overview card's headline figures.
        public static let display: Font = Font
            .system(size: 18, weight: .semibold, design: .monospaced)
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
        /// Extra leading for a template card or inspector explanation.
        public static let meta: CGFloat = 5
        /// Extra leading for the paragraph under an empty-state headline.
        public static let body: CGFloat = 7
        /// Extra leading for the JSON body editor, matching its gutter's line numbers.
        public static let code: CGFloat = 5
    }
}
