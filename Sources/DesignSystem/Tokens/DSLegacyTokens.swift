import SwiftUI

// Temporary names from the previous token set, mapped onto the redesign's values so screens that have
// not moved yet still compile. Delete this file once nothing references it.

public nonisolated extension DSColors {
    static let dominant = content
    static let secondary = window
    static let tertiary = field
    static let surfaceElevated = raised
    static let band = field
    static let rowStripe = zebra
    static let codeWell = code
    static let accentText = accent
    static let accentFill = accent
    static let accentSubtle = selectionSoft
    static let accentMuted = selectionSoft
    static let destructive = error
    static let destructiveFill = error
    static let destructiveText = error
    static let successText = success
    static let successSubtle = success.opacity(0.12)
    static let successMuted = success.opacity(0.25)
    static let warningText = warning
    static let serverRunning = success
    static let serverError = error
    static let border = fieldBorder
    static let borderFocused = accent
    static let panelSeparator = separator

    enum Journey {
        public static let accent = DSColors.accent
        public static let text = DSColors.accent
        public static let fill = DSColors.selectionSoft
    }
}

nonisolated extension DSColors {
    static let dominantLightInk = contentLightInk
    static let dominantDarkInk = contentDarkInk
    static let secondaryLightInk = windowLightInk
    static let secondaryDarkInk = windowDarkInk
    static let accentInk = Ink(0x0A84FF)
}

public extension DSTypography {
    static let label = body
    static let labelMedium = bodyMedium
    static let bodyBold = bodySemibold
    static let meta = callout
    static let metaSmall = caption
    static let metaBold = captionSemibold
    static let controlLabel = bodySemibold
    static let controlLabelQuiet = body
    static let subheading = headline
    static let heading = headline
    static let display = largeTitle
    static let codeBadge = method
    static let codeBadgeCompact = method
    static let codeBadgeStandard = method
    static let codeSmall = code
    static let codeBold: Font = .system(size: 12, weight: .medium, design: .monospaced)
    static let codePath = code
    static let codeHeading = codeLarge
}

public extension DSTypography.Figure {
    static let small = regular
    static let status = DSTypography.status.monospacedDigit()
    static let statusLarge = large
    static let display = large
}

public extension DSTypography.Leading {
    static let meta = callout
    static let body = callout
}

public extension DSSpacing {
    static let smPlus: CGFloat = 8
    static let mdMinus: CGFloat = 12
    static let mdPlus: CGFloat = 16
    static let lgPlus: CGFloat = 20
}

public extension DSCornerRadius {
    static let xs: CGFloat = mark
    static let sm: CGFloat = field
    static let smPlus: CGFloat = field
    static let md: CGFloat = field
    static let mdPlus: CGFloat = field
    static let lg: CGFloat = segment
    static let lgPlus: CGFloat = card
    static let xl: CGFloat = panel
}

public extension DSRowHeight {
    static let listRow: CGFloat = list
    static let logRow: CGFloat = table
    static let importRow: CGFloat = table
    static let compactRow: CGFloat = list
    static let journeyStep: CGFloat = step
}

public extension DSBarHeight {
    static let navigatorHeader: CGFloat = column
    static let navigatorFooter: CGFloat = footer
    static let panelHeader: CGFloat = paneHeader
    static let secondaryBar: CGFloat = jumpBar
    static let controlRow: CGFloat = 36
    static let columnHeader: CGFloat = DSRowHeight.table
}

public extension DSControlHeight {
    static let row: CGFloat = regular
    static let field: CGFloat = regular
    static let search: CGFloat = regular
    static let navigation: CGFloat = large
    static let verticalPadding: CGFloat = 3
}

public extension DSStroke {
    static let seam: CGFloat = hairline
    static let focusRing: CGFloat = emphasis
}

public extension DSGlyph {
    static let indicator: CGFloat = disclosure
    static let inlineSmall: CGFloat = disclosure
    static let inline: CGFloat = field
    static let controlLarge: CGFloat = control
    static let controlProminent: CGFloat = control
}

public extension DSSheetWidth {
    static let backendSettings: CGFloat = wide
}

public extension DSAnimation {
    static let micro: Double = 0.06
}

nonisolated public enum DSToolbarGeometry {
    public static let height: CGFloat = DSControlHeight.prominent
    public static let contentHeight: CGFloat = 16
    public static let expandedCenterWidth: CGFloat = 600
    public static let actionOverflowCenterWidth: CGFloat = 440
    public static let iconStatusCenterWidth: CGFloat = 380
    public static let projectTitleWidth: CGFloat = 200
    public static let compactProjectTitleWidth: CGFloat = 140
    public static let metadataHeight: CGFloat = 13
    public static let detailsWidth: CGFloat = DSLayout.popoverWidth
    public static let detailsListHeight: CGFloat = 320
    public static let copyButtonWidth: CGFloat = 100
    public static let compactStatusWidth: CGFloat = 120
    public static let iconStatusWidth: CGFloat = height
    public static let statusWidth: CGFloat = 280
}
