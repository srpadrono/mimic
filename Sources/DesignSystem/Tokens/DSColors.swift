import SwiftUI

/// Color role tokens — Ink & Electric palette.
/// Custom values give Mimic its own identity while respecting light/dark mode.
///
/// `nonisolated` because a palette has no actor affinity: these are immutable `Sendable` constants,
/// and the module's default `MainActor` isolation would otherwise put them out of reach of the
/// background work that formats a request body — which is precisely the work that must not run on
/// the main actor.
public nonisolated enum DSColors {
    // MARK: - Surface roles

    /// The centre editor, the request log's body, and the window behind them.
    ///
    /// **New value, not yet applied here.** `#FCFCFD` / `#1A1A1C` against ``dominant``'s
    /// `#F8F8FA` / `#1C1C1E` — lighter in light mode, darker in dark. The migration of the five
    /// call sites that draw ``dominant`` is a judgement call per site and belongs to the follow-on
    /// issue, not to the rename that landed this token.
    ///
    /// The lighter light value is what buys the headroom ``rowStripe`` needs; see that token's note.
    public static let surfaceContent = Color(light: .init(red: 0.988, green: 0.988, blue: 0.992),
                                             dark: .init(red: 0.102, green: 0.102, blue: 0.110))

    /// The navigator and the inspector — one shared material.
    ///
    /// **On macOS 26 the navigator does not take this fill at all.** A sidebar split item is handed
    /// the system material on recompile whether the app opts in or not, and the decision recorded in
    /// `docs/redesign/decisions.md` is to let it: fighting the framework to paint a flat colour under
    /// a translucent surface is work with no payoff. This value is the inspector's body, and the
    /// navigator's substrate for the purposes of reasoning about contrast — not a fill anyone draws
    /// over a sidebar.
    public static let surfaceSidebar = Color(light: .init(red: 0.945, green: 0.945, blue: 0.953),
                                             dark: .init(red: 0.137, green: 0.137, blue: 0.145))

    /// Every panel's own 30pt header, **where its host is ``surfaceContent``**.
    ///
    /// Byte-identical to the ``secondary`` it replaces — `#F0F0F2` / `#2C2C2E` in both appearances —
    /// which is what made renaming its call sites a provably zero-pixel change.
    ///
    /// The qualifier matters and is the one place the redesign's own spec was wrong. Over
    /// ``surfaceSidebar`` this measures **ΔL\* 0.30**, five times fainter than the faintest band this
    /// palette has ever allowed, which would have made the navigator's header, the inspector's header
    /// and every `DSSectionHeader` inside the inspector invisible in light mode. On those hosts a
    /// header takes **no fill** and the 0.5pt rule below it does the whole job — which is what
    /// `NSTableHeaderView` does. See ``band``.
    public static let surfacePanelHeader = Color(light: .init(red: 0.941, green: 0.941, blue: 0.949),
                                                 dark: .init(red: 0.173, green: 0.173, blue: 0.180))

    /// Filter fields, input wells, recessed areas.
    ///
    /// Byte-identical to the ``tertiary`` it replaces — `#E8E8EC` / `#3A3A3C`.
    public static let surfaceWell = Color(light: .init(red: 0.910, green: 0.910, blue: 0.925),
                                          dark: .init(red: 0.227, green: 0.227, blue: 0.235))

    /// Popovers, sheets, cards, and a lifted list row.
    ///
    /// **New value, not yet applied.** `#FFFFFF` / `#2C2C2E`. In dark this is the same value as
    /// ``surfacePanelHeader``, deliberately: elevation there is carried by the shadow, not the fill,
    /// because a near-black surface has nowhere brighter to go that does not read as grey plastic.
    ///
    /// The token has exactly one reference today and it is a preview, so every sheet and popover the
    /// design puts on it is currently drawing something else. Applying it is its own issue.
    public static let surfaceElevated = Color(light: .init(red: 1.0, green: 1.0, blue: 1.0),
                                              dark: .init(red: 0.173, green: 0.173, blue: 0.180))

    // MARK: - Superseded surface names

    /// Main window background, editor canvas.
    ///
    /// - Note: Superseded by ``surfaceContent``, which is a *different* value. Kept until its five
    ///   call sites are migrated one at a time, because each is a judgement about whether that
    ///   surface is really the content canvas.
    public static let dominant = Color(light: .init(red: 0.973, green: 0.973, blue: 0.980),
                                       dark: .init(red: 0.110, green: 0.110, blue: 0.118))

    /// Sidebar, inspector, toolbars — elevated surface.
    ///
    /// - Note: Superseded. This one name did two jobs, which is why it cannot be renamed
    ///   mechanically: some of its call sites are a panel's own header (``surfacePanelHeader``, the
    ///   same value) and some are the sidebar or inspector body (``surfaceSidebar``, a different
    ///   one). Splitting them is a per-site decision.
    public static let secondary = surfacePanelHeader

    /// Input fields, wells, recessed areas.
    ///
    /// - Note: Superseded by ``surfaceWell``, which is the identical value. No call sites remain;
    ///   kept only so an in-flight branch does not fail to compile.
    public static let tertiary = surfaceWell

    /// The band a bar wears when it sits *inside* a pane rather than above one — a column-header
    /// strip, a section divider, the jump bar. A panel's own header takes ``secondary``; this is one
    /// step off whatever it happens to be sitting on.
    ///
    /// Half of ``tertiary`` rather than a share of ``secondary``, and that is the whole point. Three
    /// bars were each written as their own wash of the panel-header surface — `secondary.opacity(0.5)`
    /// on the jump bar, `secondary.opacity(0.6)` in the request log and again in the import review —
    /// which is a band trying to be quieter by moving *towards* the tone it wants to be quieter than.
    /// In the request log it arrived: the drawer's own surface is `secondary`, so 60% of `secondary`
    /// over `secondary` is `secondary`, and the column strip and the panel header above it were the
    /// same colour with a number in the source implying they were not.
    ///
    /// Blending toward the well colour instead lands one step off the host in the direction each mode
    /// expects — darker in light, lighter in dark. Rendered and read back in sRGB, band against host:
    /// **0.9255 on 0.9412** for a `secondary` panel in light and **0.2000 on 0.1725** in dark;
    /// 0.9412 on 0.9725 and 0.1686 on 0.1098 for the editor canvas; 0.9373 on 0.9608 and 0.2118 on
    /// 0.2000 for a sheet.
    ///
    /// **"One step" is not one size, and the percentages lie about which way.** As a share of the host
    /// the panel case reads 1.6% in light against 15.6% in dark, which looks like a ten-fold asymmetry
    /// and is not one — a percentage of a near-black surface flatters dark mode enormously. On the
    /// perceptual axis the same pair is ΔL\* 1.4 against 3.2, a factor of two, and the real spread is
    /// between *hosts* rather than between modes: the faintest band in the window is a dark-mode one,
    /// on a sheet, at ΔL\* 1.4 — exactly the step light mode gets on a panel. The widest is dark mode
    /// on the editor canvas, at 7.3.
    ///
    /// **The rule separates; this only tints.** Every bar wearing this closes with a 0.5pt
    /// ``separator``, and that rule measures ΔL\* 9.9–11.3 against the band in both appearances and on
    /// all three hosts, while the band's own step ranges 1.4–7.3. The rule is the constant, the fill is
    /// the variable, and the fill is not what a section boundary is resting on in either mode.
    ///
    /// Xcode keeps the same proportion: its jump bar sits ΔL\* 2.0 off the editor canvas under a
    /// one-pixel rule of ΔL\* 11, and its file-inspector section headers take no fill at all. AppKit
    /// goes further — measured on a light screen, an `NSTableHeaderView` and the table beneath it are
    /// both pure white, separated by a single `gridColor` hairline. A band you have to look for is the
    /// right amount of band.
    public static let band = surfaceWell.opacity(0.5)

    /// The wash on every other row of a dense table.
    ///
    /// One token because four lists stripe themselves — the request log, the endpoint traffic list,
    /// the import review, and the request detail's header tables — and all four wrote
    /// `tertiary.opacity(0.25)` by hand, except the fourth, which wrote `0.2` for no stated reason.
    ///
    /// **The value is a ceiling, not a preference, and it is worth knowing why before raising it.**
    /// Measured in sRGB, this stripe differs from ``secondary`` by **ΔL\* 0.70** in light mode and
    /// 1.40 in dark. That is genuinely faint — AppKit's own
    /// `NSColor.alternatingContentBackgroundColors`, which is what Finder and Xcode's table views
    /// alternate between, measures ΔL\* **3.54** light and 5.33 dark, five times as much — and the
    /// obvious reading is that Mimic's zebra is too weak to do its job on a panel.
    ///
    /// It cannot be strengthened on its own. ``warning`` and ``success`` are read as *text* on these
    /// rows — a 401 in the request log, a 2xx in the traffic list — and on ``secondary`` they clear
    /// AA with almost nothing to spare, at 4.59:1 and 4.62:1. Darkening the row underneath spends
    /// exactly that margin: at AppKit's ΔL\* 3.5 the amber falls to **4.28:1** and the green to 4.30,
    /// both under the 4.5 this palette holds itself to. The arithmetic is tight enough to state
    /// exactly — for amber to stay at 4.5 on a striped row, the stripe may take no more than 0.9% off
    /// the surface, which is ΔL\* 0.7. This value *is* that ceiling.
    ///
    /// So a more visible zebra is not a change to this token. It is a change to ``warning`` and
    /// ``success`` first, to buy the headroom, and this token second. Both are already pushed a long
    /// way down for light mode; moving them again is a palette decision, not a layout one.
    public static let rowStripe = surfaceWell.opacity(0.25)

    /// Primary accent — electric blue
    public static let accent = Color(light: .init(red: 0.039, green: 0.518, blue: 1.0),
                                     dark: .init(red: 0.039, green: 0.518, blue: 1.0))

    /// The accent when it is a *word* rather than a fill.
    ///
    /// ``accent`` is the system blue, and it is right for what it is used for — a filled slab, a
    /// selection, a focus ring — where it sits behind white. It is not a text colour, and the palette
    /// already said so once: ``Syntax/literal`` exists because the shared blue "reads at 3.3:1 as
    /// small text on a light body". The same is true everywhere else it labels a control.
    ///
    /// Rendered in sRGB and read back, `accent` as 13pt text in light mode measured **3.20:1** on a
    /// panel, **3.65:1** on a sheet, and — worst of all — **2.80:1** on its own ``accentSubtle``
    /// hover fill. That last one is `DSButton`'s ghost variant, which is the Cancel button in every
    /// sheet in the app: the reading got *worse* the moment you pointed at it. Against the 4.5:1 this
    /// palette holds itself to, all three fail.
    ///
    /// So the light side moves down and the dark side moves up, each away from the fill blue in the
    /// direction its own background needs — the same correction ``success``, ``warning`` and
    /// ``destructive`` already carry. Measured after the change: 5.31:1 on a panel, 6.09:1 on a
    /// sheet, 4.68:1 on the hover fill in light; 5.35:1, 6.68:1 and 4.79:1 in dark. The dark variant
    /// is ``Syntax/literal``'s, because that is already this palette's answer to "a blue that is text".
    ///
    /// `accentSubtle` and `accentMuted` still derive from ``accent``: they are fills, and tinting them
    /// with the text blue would darken every hover well in the window to fix a contrast problem that
    /// belongs to the glyphs on top of it.
    public static let accentText = Color(light: .init(red: 0.0, green: 0.36, blue: 0.82),
                                         dark: .init(red: 0.316, green: 0.657, blue: 1.0))

    /// The accent when it is a *filled slab with white text on it*.
    ///
    /// ``accent`` is `NSColor.controlAccentColor`'s blue, and white on it measures **3.64:1** —
    /// rendered in sRGB and read back, in both appearances. That is below the 4.5:1 this palette holds
    /// itself to, on the most important control in every sheet: the commit button, and the
    /// call-to-action of every empty state.
    ///
    /// macOS's own prominent button has exactly the same ratio, which is why this is not a bug report
    /// against Apple and why the fix is deliberately narrow. Only the *fill under white text* moves;
    /// ``accent`` itself is unchanged, so selection fills, focus rings, hover washes and accent glyphs
    /// all keep the system blue and the app keeps looking like a Mac app. This is the same shape of
    /// correction ``accentText`` makes in the other direction — that one is the accent as a word, this
    /// one is the accent as a background.
    ///
    /// `(0.0, 0.44, 0.92)` measures **4.64:1** against white. It is the smallest step down that clears
    /// the bar with any margin: `(0.0, 0.46, 0.94)` is 4.36 and fails, and going further to
    /// ``accentText``'s 6.09 would read as navy rather than as this app's blue.
    public static let accentFill = Color(light: .init(red: 0.0, green: 0.44, blue: 0.92),
                                         dark: .init(red: 0.0, green: 0.44, blue: 0.92))

    /// Subtle accent for backgrounds (selection highlight, hover)
    public static let accentSubtle = accent.opacity(0.12)
    /// Muted accent for secondary indicators
    public static let accentMuted = accent.opacity(0.25)
    /// Destructive actions only. Light variant darkened from 3.6:1 to 5.6:1 for the same reason as
    /// ``success`` and ``warning`` — a 500 in the request log is text before it is a signal.
    public static let destructive = Color(light: .init(red: 0.80, green: 0.10, blue: 0.08),
                                          dark: .init(red: 1.0, green: 0.484, blue: 0.453))

    // MARK: - Semantic

    /// Success — green.
    ///
    /// The light variant is much darker than the dark one, and deliberately so. These are read as
    /// *text* — a 200 in the request log, "Running" in the overview — and the vibrant green that
    /// works on a near-black panel measured **2.2:1** against a light one, well under the 4.5:1 AA
    /// needs for 10–11pt. The dark variant is unchanged; only the light side moved, to 4.8:1.
    public static let success = Color(light: .init(red: 0.047, green: 0.491, blue: 0.189),
                                      dark: .init(red: 0.188, green: 0.820, blue: 0.345))

    /// Warning — amber. Same story, and worse: the shared amber measured **2.1:1** on light. Amber
    /// is the hardest hue to read on white, so the light variant is pushed a long way down — to
    /// **4.60:1** against `dominant`. Green is 0.39 rather than 0.40 for one reason: 0.40 computes
    /// to 4.49:1, which fails AA by a hundredth. Amber's luminance is almost all green, so that
    /// channel is the one to move, and one step is enough.
    public static let warning = Color(light: .init(red: 0.602, green: 0.373, blue: 0.0),
                                      dark: .init(red: 1.0, green: 0.624, blue: 0.039))

    // MARK: - Server state colors

    /// Server idle / stopped state
    public static let serverIdle = Color.secondary
    /// Server running state
    public static let serverRunning = success
    /// Server error state
    public static let serverError = destructive

    // MARK: - Text

    /// Primary label text — high contrast
    public static let labelPrimary = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.88),
                                           dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.88))

    /// Secondary label text — 60% hierarchy
    public static let labelSecondary = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.55),
                                             dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.55))

    /// Tertiary label text — timestamps, hints
    public static let labelTertiary = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.36),
                                            dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.36))

    // MARK: - Borders

    /// Subtle border for cards, inputs
    public static let border = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.09),
                                     dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.10))

    /// Focus ring border
    public static let borderFocused = accent

    /// Separator lines
    public static let separator = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.12),
                                        dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.12))

    /// Panel/drawer edge separator — the heaviest rule in the app, and measured against Xcode's.
    ///
    /// 20% was a guess, and the doc used to claim it "matches system NavigationSplitView divider
    /// weight". Measured off screen instead: Xcode draws its navigator/editor seam and its
    /// editor/inspector seam as **one physical pixel** compositing to **11.9%** and **14.2%** white
    /// over the darker surface. 20% is roughly half again as heavy as the heavier of those, and next
    /// to Xcode all day that reads as a ruled form rather than a seam.
    ///
    /// 14% sits at the top of Xcode's measured band, so this stays the heaviest rule in the ladder
    /// and still clears ``separator`` (12%) — it just stops overshooting the app it is measured
    /// against.
    public static let panelSeparator = Color(light: .init(red: 0.0, green: 0.0, blue: 0.0, opacity: 0.14),
                                             dark: .init(red: 1.0, green: 1.0, blue: 1.0, opacity: 0.14))

    // MARK: - HTTP Method Colors

    /// Maps an HTTP method string to a distinct, selection-safe color.
    public static func methodColor(for method: String) -> Color {
        switch method.uppercased() {
        case "GET":              Color(light: .init(red: 0.0, green: 0.413, blue: 0.393),
                                       dark: .init(red: 0.259, green: 0.784, blue: 0.757))
        case "POST":             Color(light: .init(red: 0.110, green: 0.424, blue: 0.197),
                                       dark: .init(red: 0.306, green: 0.812, blue: 0.427))
        case "PUT":              Color(light: .init(red: 0.520, green: 0.328, blue: 0.055),
                                       dark: .init(red: 1.0, green: 0.694, blue: 0.306))
        case "PATCH":            Color(light: .init(red: 0.505, green: 0.239, blue: 0.697),
                                       dark: .init(red: 0.749, green: 0.478, blue: 0.969))
        case "DELETE":           Color(light: .init(red: 0.663, green: 0.196, blue: 0.196),
                                       dark: .init(red: 1.0, green: 0.392, blue: 0.392))
        case "HEAD", "OPTIONS":  Color(light: .init(red: 0.371, green: 0.371, blue: 0.386),
                                       dark: .init(red: 0.627, green: 0.627, blue: 0.647))
        default:                 .secondary
        }
    }

    // MARK: - Syntax colors

    /// Colors for rendering a JSON payload.
    ///
    /// Drawn from the same hues as ``methodColor(for:)`` rather than a stock editor theme, so a
    /// coloured body reads as part of Mimic instead of an embedded text editor. Keys carry the most
    /// saturated hue because scanning a response means scanning its keys.
    /// Every light variant here is darker than its `methodColor` cousin, and that is the point.
    ///
    /// A method badge is three bold characters on a tinted pill; a payload is hundreds of 11pt
    /// monospaced characters on a near-white surface, and it is the densest reading in the app.
    /// Measured against that surface, the badge hues gave 2.2:1 for numbers and 2.8:1 for strings —
    /// under half the 4.5:1 that 11pt text needs. The dark variants were already fine and are
    /// untouched; only the light side moved.
    ///
    /// **The surface to measure against is the well, not the window.** These are drawn inside
    /// `DSJSONEditor` and `DSCodeBlock`, whose fill is ``tertiary`` — a step darker than the canvas,
    /// so it is the harder of the two backgrounds and the one the numbers below are taken on.
    /// Rendered in sRGB and read back there, two of the four had not in fact cleared the bar the
    /// paragraph above sets: `number` measured **4.00:1** and `literal` **4.40:1** in light mode
    /// while `key` and `string` sat at 6.46 and 4.87. Both now clear it — 4.65 and 4.63 — and neither
    /// dark variant is touched.
    public enum Syntax {
        /// Object keys — the thing you actually look for in a payload.
        public static let key = Color(light: .init(red: 0.46, green: 0.14, blue: 0.70),
                                      dark: .init(red: 0.749, green: 0.478, blue: 0.969))

        /// String values.
        public static let string = Color(light: .init(red: 0.0, green: 0.44, blue: 0.42),
                                         dark: .init(red: 0.259, green: 0.784, blue: 0.757))

        /// Numeric values. Amber is the hardest hue to carry on a light surface — its luminance is
        /// almost all green — so the light variant is the one that had furthest to move.
        public static let number = Color(light: .init(red: 0.58, green: 0.35, blue: 0.0),
                                         dark: .init(red: 1.0, green: 0.694, blue: 0.306))

        /// `true`, `false`, and `null`. Not `accent`: the shared blue is tuned for fills and
        /// selection, where it sits behind white, and reads at 3.3:1 as small text on a light body.
        /// This is the same reasoning ``DSColors/accentText`` carries, and the same dark value.
        public static let literal = Color(light: .init(red: 0.0, green: 0.38, blue: 0.85),
                                          dark: .init(red: 0.316, green: 0.657, blue: 1.0))

        /// Braces, brackets, commas, colons — structure, deliberately quiet.
        public static let punctuation = labelTertiary

        /// Background behind a search hit inside a body.
        public static let searchHit = warning.opacity(0.35)
    }

    // MARK: - HTTP status code color

    /// Maps an HTTP status code to a semantic color.
    public static func httpStatusColor(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: success
        case 300..<400: accent
        case 400..<500: warning
        case 500..<600: destructive
        default: .secondary
        }
    }
}

/// Server state mapped to color.
public enum DSServerState {
    case idle
    case running
    case stopped
    case error

    public var color: Color {
        switch self {
        case .idle, .stopped: DSColors.serverIdle
        case .running: DSColors.serverRunning
        case .error: DSColors.serverError
        }
    }

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .stopped: "Stopped"
        case .error: "Error"
        }
    }
}

// MARK: - Color convenience for light/dark adaptive colors

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
