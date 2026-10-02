import SwiftUI

/// Adaptive colour roles shared by SwiftUI, the native editor, and background body formatting.
///
/// Every role resolves per appearance: light, dark, and both Increase Contrast variants. The accent
/// follows the system accent setting; blue is only the default. Text roles are checked against the
/// surfaces they sit on in `DSContrastTests`.
public nonisolated enum DSColors {
    /// sRGB components shared with native editor themes to avoid a second palette.
    nonisolated struct Ink: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        init(_ hex: UInt32, alpha: CGFloat = 1) {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
            self.alpha = alpha
        }

        init(white: CGFloat, alpha: CGFloat) {
            red = white
            green = white
            blue = white
            self.alpha = alpha
        }

        init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        func nsColor(opacity: CGFloat? = nil) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity ?? alpha)
        }
    }

    // MARK: - Surfaces

    static let windowLightInk = Ink(0xF6F6F7)
    static let windowDarkInk = Ink(0x1E1E20)
    /// The window behind the floating sidebar, inspector, and content surface.
    public static let window = Color(light: windowLightInk, dark: windowDarkInk)

    static let contentLightInk = Ink(0xFFFFFF)
    static let contentDarkInk = Ink(0x1B1B1D)
    /// The one content surface: the editor, the request log, and lists that fill a pane.
    public static let content = Color(light: contentLightInk, dark: contentDarkInk)

    static let codeLightInk = Ink(0xFBFBFC)
    static let codeDarkInk = Ink(0x161618)
    /// Code and body wells.
    public static let code = Color(light: codeLightInk, dark: codeDarkInk)

    /// Sheets, popovers, and cards raised above the window.
    public static let raised = Color(light: Ink(0xFFFFFF), dark: Ink(0x2C2C2F))

    /// A sheet's own background.
    public static let sheet = Color(light: Ink(0xF7F7F8), dark: Ink(0x2A2A2D))

    /// The source list down the side of a sheet, a step darker than the sheet in either scheme.
    public static let sheetSidebar = Color(light: Ink(0xEFEFF2), dark: Ink(0x242427))

    /// The welcome window's identity column, with the app icon and start actions: the Welcome
    /// board's `--win`.
    public static let welcomeHero = Color(light: Ink(0xFFFFFF), dark: Ink(0x1E1E20))

    /// The welcome window's recent-projects column: the Welcome board's `--side`.
    public static let welcomeSide = Color(light: Ink(0xF3F3F5), dark: Ink(0x26262A))

    /// The fill inside a field, a segmented track, or a secondary button.
    public static let field = Color(light: Ink(white: 0, alpha: 0.045), dark: Ink(white: 1, alpha: 0.065))

    /// The hairline around a field or a secondary button.
    public static let fieldBorder = Color(
        light: Ink(white: 0, alpha: 0.13), dark: Ink(white: 1, alpha: 0.10),
        lightHighContrast: Ink(white: 0, alpha: 0.4), darkHighContrast: Ink(white: 1, alpha: 0.4)
    )

    /// A field or secondary button inside a sheet. Light sheets draw it white with a firmer hairline,
    /// so it stands off the sheet's grey; dark sheets keep the window's field.
    public static let sheetField = Color(light: Ink(0xFFFFFF), dark: Ink(white: 1, alpha: 0.065))

    /// The hairline around a field or secondary button inside a sheet.
    public static let sheetFieldBorder = Color(
        light: Ink(white: 0, alpha: 0.14), dark: Ink(white: 1, alpha: 0.10),
        lightHighContrast: Ink(white: 0, alpha: 0.4), darkHighContrast: Ink(white: 1, alpha: 0.4)
    )

    /// A grouped settings card in a sheet: white in light, a step above the sheet in dark.
    public static let formGroup = Color(light: Ink(0xFFFFFF), dark: Ink(white: 1, alpha: 0.045))

    /// A well of read-only text inside a sheet, such as release notes: white in light, a step below
    /// the sheet in dark.
    public static let sheetWell = Color(light: Ink(0xFFFFFF), dark: Ink(white: 0, alpha: 0.2))

    /// A settings switch's track while off.
    public static let switchTrack = Color(light: Ink(white: 0, alpha: 0.14), dark: Ink(white: 1, alpha: 0.18))

    /// A settings switch's knob.
    public static let switchKnob = Color(light: Ink(0xFFFFFF), dark: Ink(0xF2F2F2))

    /// The raised segment inside a segmented control.
    public static let segmentSelected = Color(light: Ink(0xFFFFFF), dark: Ink(white: 1, alpha: 0.16))

    /// A row or button under the pointer.
    public static let hover = Color(light: Ink(white: 0, alpha: 0.05), dark: Ink(white: 1, alpha: 0.06))

    /// Alternate table rows.
    public static let zebra = Color(light: Ink(white: 0, alpha: 0.025), dark: Ink(white: 1, alpha: 0.028))

    /// A selected row while its list does not have focus.
    public static let selectionInactive = Color(light: Ink(white: 0, alpha: 0.09), dark: Ink(white: 1, alpha: 0.12))

    /// The dimming layer behind a sheet in a screenshot or preview.
    public static let scrim = Color(light: Ink(white: 0, alpha: 0.18), dark: Ink(white: 0, alpha: 0.45))

    // MARK: - Labels

    public static let labelPrimary = Color(light: Ink(white: 0, alpha: 0.88), dark: Ink(white: 1, alpha: 0.92))

    /// Secondary text: values beside a label, timestamps, hints.
    public static let labelSecondary = Color(
        light: Ink(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.72),
        dark: Ink(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.62),
        lightHighContrast: Ink(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.9),
        darkHighContrast: Ink(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.85)
    )

    /// Section headers, placeholders, units, and disabled content.
    public static let labelTertiary = Color(
        light: Ink(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.58),
        dark: Ink(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.38),
        lightHighContrast: Ink(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.72),
        darkHighContrast: Ink(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.62)
    )

    // MARK: - Separators

    /// Every rule in the window: one pixel, never a heavier seam.
    public static let separator = Color(
        light: Ink(white: 0, alpha: 0.09), dark: Ink(white: 1, alpha: 0.08),
        lightHighContrast: Ink(white: 0, alpha: 0.2), darkHighContrast: Ink(white: 1, alpha: 0.22)
    )

    // MARK: - Accent

    /// The system accent. Selection, focus, primary buttons, and links.
    public static let accent = Color.accentColor

    /// A soft accent wash: the scenario being edited, the current journey step.
    public static let selectionSoft = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.22 : 0.12)
    })

    /// The focus ring's halo.
    public static let focusRing = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.keyboardFocusIndicatorColor.withAlphaComponent(appearance.isDark ? 0.5 : 0.4)
    })

    static let selectionLightInk = Ink(0x0A74F0)
    static let selectionDarkInk = Ink(0x0A6CE0)

    /// A selected row's solid fill, under white text: the welcome window's recents, the sidebar row
    /// and the shared table.
    ///
    /// With the default blue accent it is the boards' `--sel`, #0A74F0 light and #0A6CE0 dark, a
    /// step deeper than the accent so white text reads on it. With any other accent, and under
    /// Increase Contrast, it is the system's selected-content colour, so selection still follows
    /// the user's choice. See ``isDefaultBlue(_:)`` for how the default is recognised.
    public static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        DSColors.selectionColor(accent: NSColor.controlAccentColor, isDark: appearance.isDark,
                                isHighContrast: appearance.isHighContrast)
    })

    /// The selection fill for one accent and appearance. Split out of ``selection`` so a test can
    /// pass an accent rather than depend on the machine's setting.
    static func selectionColor(accent: NSColor, isDark: Bool, isHighContrast: Bool) -> NSColor {
        guard !isHighContrast, isDefaultBlue(accent) else {
            return NSColor.selectedContentBackgroundColor
        }
        return (isDark ? selectionDarkInk : selectionLightInk).nsColor()
    }

    /// Whether `accent` is the default blue: the system blue (#007AFF light, #0A84FF dark), or
    /// Mimic's own #0A84FF accent, which `controlAccentColor` returns when the system accent is
    /// Multicolor.
    ///
    /// Recognised by hue, not by equality or by the `AppleAccentColor` default: the two blues differ
    /// per appearance and per accent setting, the default's encoding is private, and a hue check
    /// holds for each of them while every other accent (purple, pink, red, orange, yellow, green,
    /// graphite) is at least 40 degrees away or unsaturated.
    static func isDefaultBlue(_ accent: NSColor) -> Bool {
        guard let srgb = accent.usingColorSpace(.sRGB) else { return false }
        // System blue sits at about 211 degrees in both appearances.
        let hueDegrees = srgb.hueComponent * 360
        return abs(hueDegrees - 211) <= 8 && srgb.saturationComponent >= 0.7 && srgb.brightnessComponent >= 0.7
    }

    // MARK: - Status

    static let successLightInk = Ink(0x157A36)
    static let successDarkInk = Ink(0x34D06C)
    /// 2xx, running, live.
    public static let success = Color(light: successLightInk, dark: successDarkInk)

    /// 3xx.
    public static let redirect = Color(light: Ink(0x0A62CC), dark: Ink(0x5AA9FF))

    static let warningLightInk = Ink(0x965900)
    static let warningDarkInk = Ink(0xFFB340)
    /// 4xx, unmatched, restart needed.
    public static let warning = Color(light: warningLightInk, dark: warningDarkInk)

    static let errorLightInk = Ink(0xCC302B)
    static let errorDarkInk = Ink(0xFF5F57)
    /// 5xx, failures, destructive actions.
    public static let error = Color(light: errorLightInk, dark: errorDarkInk)

    /// Banner fills.
    public static let warningBackground = Color(light: Ink(0xFF9F0A, alpha: 0.12), dark: Ink(0xFFB340, alpha: 0.12))
    public static let errorBackground = Color(light: Ink(0xFF3B30, alpha: 0.10), dark: Ink(0xFF5F57, alpha: 0.12))
    public static let infoBackground = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.14 : 0.10)
    })

    /// Status text and dot colour for an HTTP status code.
    public static func httpStatusColor(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: success
        case 300..<400: redirect
        case 400..<500: warning
        case 500..<600: error
        default: labelSecondary
        }
    }

    // MARK: - Project tiles

    /// The monogram tiles in the welcome window's project list. White text sits on all four in both
    /// appearances, so they do not adapt; a project keeps its colour for as long as it keeps its id.
    public static let projectTiles: [Color] = [
        Color(light: Ink(0x0A84FF), dark: Ink(0x0A84FF)),
        Color(light: Ink(0x34A853), dark: Ink(0x34A853)),
        Color(light: Ink(0xAF52DE), dark: Ink(0xAF52DE)),
        Color(light: Ink(0xFF9F0A), dark: Ink(0xFF9F0A)),
    ]

    // MARK: - Methods

    /// Method text colour. Hue and lightness both differ, so methods stay apart without colour.
    public static func methodColor(for method: String) -> Color {
        switch method.uppercased() {
        case "GET": Color(light: Ink(0x0A62CC), dark: Ink(0x5AA9FF))
        case "POST": Color(light: Ink(0x18823A), dark: Ink(0x4FD07B))
        case "PUT": Color(light: Ink(0xA85A00), dark: Ink(0xFFA94D))
        case "PATCH": Color(light: Ink(0x8433C4), dark: Ink(0xC79BFF))
        case "DELETE": Color(light: Ink(0xC42B27), dark: Ink(0xFF6B66))
        default: Color(light: Ink(0x62626A), dark: Ink(0xA1A1AA))
        }
    }

    // MARK: - Syntax

    /// JSON syntax colours; the native editor shares these components.
    public enum Syntax {
        static let keyLightInk = Ink(0x8A2FC4)
        static let keyDarkInk = Ink(0xC490FF)
        public static let key = Color(light: keyLightInk, dark: keyDarkInk)

        static let stringLightInk = Ink(0x00766F)
        static let stringDarkInk = Ink(0x4FD1C5)
        public static let string = Color(light: stringLightInk, dark: stringDarkInk)

        static let numberLightInk = Ink(0x945A00)
        static let numberDarkInk = Ink(0xFFB14E)
        public static let number = Color(light: numberLightInk, dark: numberDarkInk)

        static let literalLightInk = Ink(0x0060D9)
        static let literalDarkInk = Ink(0x5AA9FF)
        public static let literal = Color(light: literalLightInk, dark: literalDarkInk)

        public static let punctuation = labelSecondary
    }
}

// MARK: - Appearance resolution

nonisolated extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastAqua]).map {
            $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }

    var isHighContrast: Bool {
        bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                         .aqua, .darkAqua]).map {
            $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }
}

nonisolated extension Color {
    init(light: DSColors.Ink, dark: DSColors.Ink,
         lightHighContrast: DSColors.Ink? = nil, darkHighContrast: DSColors.Ink? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let ink: DSColors.Ink
            switch (appearance.isDark, appearance.isHighContrast) {
            case (true, true): ink = darkHighContrast ?? dark
            case (true, false): ink = dark
            case (false, true): ink = lightHighContrast ?? light
            case (false, false): ink = light
            }
            return ink.nsColor()
        })
    }
}
