import SwiftUI

/// Adaptive color roles shared by SwiftUI, the native editor, and background body formatting.
/// Text colors are checked against their composited surfaces in `DSContrastTests`.
public nonisolated enum DSColors {
    /// sRGB components shared with native editor themes to avoid a second palette.
    nonisolated struct Ink: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        func nsColor(opacity: CGFloat = 1.0) -> NSColor {
            NSColor(red: red, green: green, blue: blue, opacity: opacity)
        }
    }

    // MARK: - Surfaces

    // The editor canvas contrasts with the native sidebar and inspector materials.
    static let dominantLightInk = Ink(red: 1.0, green: 1.0, blue: 1.0)
    static let dominantDarkInk = Ink(red: 0.074, green: 0.074, blue: 0.082)
    public static let dominant = Color(light: dominantLightInk.nsColor(),
                                       dark: dominantDarkInk.nsColor())

    static let secondaryLightInk = Ink(red: 0.941, green: 0.941, blue: 0.949)
    static let secondaryDarkInk = Ink(red: 0.173, green: 0.173, blue: 0.180)
    /// Panel and toolbar background.
    public static let secondary = Color(light: secondaryLightInk.nsColor(),
                                        dark: secondaryDarkInk.nsColor())

    /// Input wells and inset controls.
    public static let tertiary = Color(light: .init(red: 0.910, green: 0.910, blue: 0.925),
                                       dark: .init(red: 0.227, green: 0.227, blue: 0.235))

    /// App-owned elevated surfaces. Native sheet materials remain system controlled.
    public static let surfaceElevated = Color(light: .init(red: 0.961, green: 0.961, blue: 0.969),
                                              dark: .init(red: 0.200, green: 0.200, blue: 0.208))

    /// Header wash over its host surface; pair with a separator to mark the boundary.
    public static let band = tertiary.opacity(0.5)

    /// Subtle alternating row wash that preserves semantic text contrast.
    public static let rowStripe = tertiary.opacity(0.25)

    /// Read-only body background, composited over the canvas or a panel.
    public static let codeWell = tertiary.opacity(0.3)

    // MARK: - Accent and semantic roles

    static let accentInk = Ink(red: 0.039, green: 0.518, blue: 1.0)

    /// Accent for outlines, selection, and decorative fills. Use `accentText` for text.
    public static let accent = Color(light: accentInk.nsColor(), dark: accentInk.nsColor())

    /// Accent text on plain surfaces and selection washes.
    public static let accentText = Color(light: .init(red: 0.0, green: 0.36, blue: 0.82),
                                         dark: .init(red: 0.316, green: 0.657, blue: 1.0))

    /// Opaque accent fill for white button labels in either appearance.
    public static let accentFill = Color(light: .init(red: 0.0, green: 0.44, blue: 0.92),
                                         dark: .init(red: 0.0, green: 0.44, blue: 0.92))

    /// Selection and hover wash derived from the decorative accent.
    public static let accentSubtle = accent.opacity(0.12)
    /// Stronger accent wash for borders and decorative marks.
    public static let accentMuted = accent.opacity(0.25)
    /// Destructive marks and text on plain canvas or panel surfaces.
    public static let destructive = Color(light: .init(red: 0.80, green: 0.10, blue: 0.08),
                                          dark: .init(red: 1.0, green: 0.484, blue: 0.453))

    /// Opaque destructive button fill that preserves white-label contrast.
    public static let destructiveFill = Color(light: .init(red: 0.80, green: 0.10, blue: 0.08),
                                              dark: .init(red: 0.80, green: 0.10, blue: 0.08))

    /// Success marks and text on plain canvas or panel surfaces.
    public static let success = Color(light: .init(red: 0.047, green: 0.491, blue: 0.189),
                                      dark: .init(red: 0.188, green: 0.820, blue: 0.345))

    /// Warning marks and text on plain canvas or panel surfaces.
    public static let warning = Color(light: .init(red: 0.602, green: 0.373, blue: 0.0),
                                      dark: .init(red: 1.0, green: 0.624, blue: 0.039))

    /// Journey states use the shared accent family.
    public enum Journey {
        public static let accent = DSColors.accent

        public static let text = DSColors.accentText

        public static let fill = Color(light: DSColors.accentInk.nsColor(opacity: 0.11),
                                       dark: DSColors.accentInk.nsColor(opacity: 0.15))
    }

    /// Semantic text variants remain readable on their own tinted status-pill fills.
    public static let successText = Color(light: .init(red: 0.038, green: 0.403, blue: 0.154),
                                          dark: .init(red: 0.188, green: 0.820, blue: 0.345))

    /// Running-server well fill; validate text on the resulting composite.
    public static let successSubtle = success.opacity(0.12)
    /// Border or state chip on a running-server well.
    public static let successMuted = success.opacity(0.25)

    /// Warning text on plain surfaces or its own tinted fill.
    public static let warningText = Color(light: .init(red: 0.491, green: 0.305, blue: 0.0),
                                          dark: .init(red: 1.0, green: 0.624, blue: 0.039))

    /// Destructive text on plain surfaces or its own tinted fill.
    public static let destructiveText = Color(light: .init(red: 0.674, green: 0.084, blue: 0.067),
                                              dark: .init(red: 1.0, green: 0.565, blue: 0.539))

    // MARK: - Server states

    public static let serverRunning = success
    public static let serverError = destructive

    // MARK: - Labels

    /// Primary content text.
    public static let labelPrimary = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.88),
                                           dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.88))

    /// Secondary content text, including timestamps, hints, and code punctuation.
    public static let labelSecondary = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.66),
                                             dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.66))

    /// Decorative or disabled content only; this token does not meet normal-text contrast.
    public static let labelTertiary = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.36),
                                            dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.36))

    // MARK: - Borders

    /// Subtle outline for fields and cards.
    public static let border = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.09),
                                     dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.10))

    /// Focus indication on an interactive control.
    public static let borderFocused = accent

    /// Internal dividing rule.
    public static let separator = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.12),
                                        dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.12))

    /// Strongest dividing rule, used at panel boundaries.
    public static let panelSeparator = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.14),
                                             dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.14))

    // MARK: - Protocol labels

    /// Method-badge ink, checked on its 16% tint across app-owned row backgrounds.
    /// Native sidebar selection colors also require visual verification on supported macOS versions.
    public static func methodColor(for method: String) -> Color {
        switch method.uppercased() {
        case "GET":              Color(light: .init(red: 0.0, green: 0.368, blue: 0.350),
                                       dark: .init(red: 0.337, green: 0.808, blue: 0.784))
        case "POST":             Color(light: .init(red: 0.098, green: 0.377, blue: 0.175),
                                       dark: .init(red: 0.345, green: 0.824, blue: 0.459))
        case "PUT":              Color(light: .init(red: 0.463, green: 0.292, blue: 0.049),
                                       dark: .init(red: 1.0, green: 0.694, blue: 0.306))
        case "PATCH":            Color(light: .init(red: 0.450, green: 0.213, blue: 0.620),
                                       dark: .init(red: 0.839, green: 0.667, blue: 0.980))
        case "DELETE":           Color(light: .init(red: 0.592, green: 0.175, blue: 0.175),
                                       dark: .init(red: 1.0, green: 0.624, blue: 0.624))
        case "HEAD", "OPTIONS":  Color(light: .init(red: 0.330, green: 0.330, blue: 0.343),
                                       dark: .init(red: 0.737, green: 0.737, blue: 0.753))
        default:                 labelSecondary
        }
    }

    /// JSON syntax colors for read-only bodies; the native editor shares value-color components.
    public enum Syntax {
        /// Object keys.
        static let keyLightInk = Ink(red: 0.46, green: 0.14, blue: 0.70)
        static let keyDarkInk = Ink(red: 0.749, green: 0.478, blue: 0.969)
        public static let key = Color(light: keyLightInk.nsColor(), dark: keyDarkInk.nsColor())

        /// String values.
        static let stringLightInk = Ink(red: 0.0, green: 0.44, blue: 0.42)
        static let stringDarkInk = Ink(red: 0.259, green: 0.784, blue: 0.757)
        public static let string = Color(light: stringLightInk.nsColor(), dark: stringDarkInk.nsColor())

        /// Numeric values.
        static let numberLightInk = Ink(red: 0.58, green: 0.35, blue: 0.0)
        static let numberDarkInk = Ink(red: 1.0, green: 0.694, blue: 0.306)
        public static let number = Color(light: numberLightInk.nsColor(), dark: numberDarkInk.nsColor())

        /// JSON boolean and null literals.
        static let literalLightInk = Ink(red: 0.0, green: 0.38, blue: 0.85)
        static let literalDarkInk = Ink(red: 0.316, green: 0.657, blue: 1.0)
        public static let literal = Color(light: literalLightInk.nsColor(), dark: literalDarkInk.nsColor())

        /// Structural characters are readable text, including when inspecting malformed JSON.
        public static let punctuation = labelSecondary

        /// Search-result wash; always pair with `searchHitText` to preserve contrast.
        public static let searchHit = warning.opacity(0.35)

        /// Overrides syntax ink inside a search match.
        public static let searchHitText = labelPrimary
    }

    /// Semantic status text. Only 4xx, 5xx, and transport failures receive a fill in `DSStatusPill`.
    /// Redirect text does not meet the contrast floor on a tint of itself.
    public static func httpStatusColor(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: successText
        case 300..<400: accentText
        case 400..<500: warningText
        case 500..<600: destructiveText
        default: labelSecondary
        }
    }
}

// MARK: - Appearance resolution
private nonisolated extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark
            }
            return light
        })
    }
}

private nonisolated extension NSColor {
    convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat = 1.0) {
        self.init(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}
