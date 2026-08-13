import SwiftUI

/// Color role tokens — Ink & Electric palette.
/// Custom values give Mimic its own identity while respecting light/dark mode.
///
/// `nonisolated` because a palette has no actor affinity: these are immutable `Sendable` constants,
/// and the module's default `MainActor` isolation would otherwise put them out of reach of the
/// background work that formats a request body — which is precisely the work that must not run on
/// the main actor.
public nonisolated enum DSColors {
    // MARK: - Surface roles (60/30/10 rule)

    /// Main window background, editor canvas
    public static let dominant = Color(light: .init(red: 0.973, green: 0.973, blue: 0.980),
                                       dark: .init(red: 0.110, green: 0.110, blue: 0.118))

    /// Sidebar, inspector, toolbars — elevated surface
    public static let secondary = Color(light: .init(red: 0.941, green: 0.941, blue: 0.949),
                                        dark: .init(red: 0.173, green: 0.173, blue: 0.180))

    /// Input fields, wells, recessed areas
    public static let tertiary = Color(light: .init(red: 0.910, green: 0.910, blue: 0.925),
                                       dark: .init(red: 0.227, green: 0.227, blue: 0.235))

    /// Popovers, sheets — slightly brighter than secondary
    public static let surfaceElevated = Color(light: .init(red: 0.961, green: 0.961, blue: 0.969),
                                              dark: .init(red: 0.200, green: 0.200, blue: 0.208))

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
    public static let band = tertiary.opacity(0.5)

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
    /// **There is a ceiling, and this value is no longer sitting on it.** The argument here used to
    /// be that ``warning`` and ``success`` are read as text on these rows, clear AA on ``secondary``
    /// by a hundredth, and lose that margin the moment the row darkens — so ΔL\* 0.7 was the most a
    /// stripe could take. It was right about the mechanism and is out of date about the tokens: a
    /// status code on a striped row is ``warningText`` or ``successText`` now, and those clear AA on
    /// a stripe at **5.47:1** and 5.53 rather than 4.52 and 4.54. Plain status text would survive a
    /// stripe down to ΔL\* 8.
    ///
    /// What sets the ceiling instead is the *filled* pill — a 4xx or 5xx, which draws its label on a
    /// 12% tint of that same label colour, so the stripe's depth is paid twice. Measured on
    /// ``secondary`` in light: at this depth the three filled pills read **4.65:1**, 4.68 and 4.64,
    /// and at AppKit's ΔL\* 3.5 they fall to 4.34, 4.36 and **4.33**, all under the 4.5 this palette
    /// holds itself to. The crossing is at **ΔL\* 1.8**, set by ``destructiveText`` as the tightest of
    /// the three.
    ///
    /// So the zebra has about one and a half ΔL\* of headroom it did not have before, and taking it
    /// is a change to this token alone — no longer a palette decision first. It still cannot reach
    /// AppKit's depth: at ΔL\* 3.5 a filled 500 misses AA, and *that* is the wall.
    ///
    /// The old ceiling is still asserted next to the new one in `DSContrastTests.rowStripeIsACeiling`,
    /// because ``warning`` and ``success`` did not move — only what draws a status code did.
    public static let rowStripe = tertiary.opacity(0.25)

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
    ///
    /// **This is also the blue a 3xx is drawn in** — `httpStatusColor(for:)` returned ``accent``
    /// there, which is the same defect one more place: 3.20:1 on a panel, and 2.80 once the pill
    /// tinted itself. It is the model the three semantic ``warningText``-style tokens were built
    /// from, and the one arm of that function still short of the floor when a caller fills it; the
    /// note on `httpStatusColor(for:)` says why that is a call-site rule rather than another colour.
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
    /// ``success`` and ``warning`` — a failure is text before it is a signal. A **500** is
    /// ``destructiveText``, not this one: it arrives on a 12% tint of itself and this constant reads
    /// 4.07 there.
    public static let destructive = Color(light: .init(red: 0.80, green: 0.10, blue: 0.08),
                                          dark: .init(red: 1.0, green: 0.484, blue: 0.453))

    // MARK: - Semantic

    /// Success — green.
    ///
    /// The light variant is much darker than the dark one, and deliberately so. These are read as
    /// *text* — "Running" in the overview, the server dot beside it — and the vibrant green that
    /// works on a near-black panel measured **2.2:1** against a light one, well under the 4.5:1 AA
    /// needs for 10–11pt. The dark variant is unchanged; only the light side moved, to 4.8:1.
    ///
    /// A **200** is ``successText``: two of the lists that draw one fill the pill behind it with a
    /// 12% tint of the label's own colour, where this constant reads 3.94.
    public static let success = Color(light: .init(red: 0.047, green: 0.491, blue: 0.189),
                                      dark: .init(red: 0.188, green: 0.820, blue: 0.345))

    /// Warning — amber. Same story, and worse: the amber the light side split off from — the dark
    /// variant below, which both appearances used to share — measures **2.06:1** against white. Amber
    /// is the hardest hue to carry on a light surface, because its luminance is almost all green, so
    /// the light variant is pushed a long way down: **4.60:1** on `secondary` and **4.94** on
    /// `dominant`.
    ///
    /// Both surfaces are named because the panel is the one that decides. It is the harder of the
    /// two, it is where this amber is read as a *word* — the import review's "Body dropped" flag, a
    /// blocked-by-journey outcome, a search-hit count — and it clears AA there by a tenth.
    ///
    /// Every one of those three is a plain word on a plain surface, which is the only thing this
    /// constant is measured for. The list named a fourth, the import review's "Duplicate" flag, and
    /// that one was wrong when it was written: `ImportReviewList` draws it on a 12% tint of itself,
    /// where this amber reads 3.96 rather than 4.60 — a failure, cited as the example of a pass. It
    /// is ``warningText`` now, so it is no longer a call site of this token at all. Check what a
    /// candidate example is drawn *on* before adding it here; that is the whole distinction between
    /// these two tokens.
    ///
    /// The green channel is what moves to buy that, and it stops at 0.373 because the margin
    /// is genuinely that thin: 0.384 already reads **4.48** on a panel and misses, 0.39 reads 4.44,
    /// 0.40 reads 4.32. A hundredth of this one channel is the whole difference.
    ///
    /// This paragraph used to attribute its 4.60 to `dominant` — the *easier* surface, which
    /// understated the margin on the canvas and overstated how near the floor the amber sits on a
    /// panel — and to argue for "0.39 rather than 0.40", neither of which is the constant below and
    /// neither of which clears a panel. `DSContrastTests.semanticColoursClearAAAsText` pins all three
    /// channels and both readings, so the constant and the argument about it cannot drift apart again.
    ///
    /// **A 404 in the request log is ``warningText``, not this**, and the same goes for every other
    /// status code the window draws: `httpStatusColor(for:)` returns the text variants, because a
    /// status pill fills itself with a 12% tint of its own label colour and this constant does not
    /// survive that. See ``warningText``.
    public static let warning = Color(light: .init(red: 0.602, green: 0.373, blue: 0.0),
                                      dark: .init(red: 1.0, green: 0.624, blue: 0.039))

    // MARK: - Semantic colours as words on a tint of themselves

    /// Success — green, on a tint of itself.
    ///
    /// See ``warningText`` for why these three exist; this is the 2xx of the set. Light moves from
    /// `(0.047, 0.491, 0.189)` to `(0.041, 0.433, 0.166)` — **5.63:1** on a panel where ``success``
    /// reads 4.62, **4.72** on its own 12% tint there, and **4.59** on the worst bed a pill lands on
    /// (a ``band``). Dark is ``success``'s own constant, unchanged, because it needed no move: the
    /// vibrant green already reads 5.49 on its own tint on a panel and 5.00 on a band.
    public static let successText = Color(light: .init(red: 0.041, green: 0.433, blue: 0.166),
                                          dark: .init(red: 0.188, green: 0.820, blue: 0.345))

    /// Warning — amber, on a tint of itself. **This is the token the other two are documented from.**
    ///
    /// ``success``, ``warning`` and ``destructive`` each carry a light variant pushed down until it
    /// cleared 4.5:1 *on a panel*, and each is measured that way below and in `DSContrastTests`. The
    /// window does not draw them that way. A status pill labels itself in `httpStatusColor(for:)` and
    /// fills itself with **that same colour at 12%**, so the surface moves toward the ink and the
    /// margin those constants were chosen for is spent before anybody reads them. Rendered in sRGB
    /// and read back on ``secondary`` in light, the composite measures **3.94:1** for ``success``,
    /// **3.96** for ``warning``, **4.07** for ``destructive`` and **2.80** for ``accent`` — four
    /// failures under a floor all four clear as bare text (4.62, 4.60, 4.95, and the accent's own
    /// 3.20, which never cleared it at all).
    ///
    /// This is exactly the split ``accentText`` already makes, arriving one place later: there the
    /// fill and the word are two tokens, and here they had been one. A self-tint costs between 13%
    /// and 18% of the ratio in light mode — 13.9 for the amber, 14.7 for the green, 17.8 for the red
    /// — and no amount of tinting buys it back, so the word moves instead, far enough to survive its
    /// own 12% fill on every surface a pill actually lands on: the panel, the canvas, a sheet, a
    /// ``band`` and a ``rowStripe``. The `band` case is the binding one, and it is a real one — the
    /// request detail's identity row is a `band` and its status pill sits on it.
    ///
    /// The amber is the tightest of the three, for the reason ``warning`` gives: its luminance is
    /// almost all green. `(0.602, 0.373, 0.0)` becomes `(0.534, 0.331, 0.0)` — **5.57:1** plain on a
    /// panel, **4.71** on its own tint there, **4.56** on a `band`. Dark is ``warning``'s constant
    /// untouched; the vibrant amber reads 5.40 on its own tint on a panel and 4.92 on a band, so
    /// only the light side had anywhere to go. That asymmetry is the same one every other correction
    /// in this file makes.
    ///
    /// ``warning`` itself is unchanged and still correct for what it is — a word on a plain surface,
    /// and the hue ``Syntax/searchHit`` is a wash of. Reach for this one when the same colour is also
    /// the fill.
    public static let warningText = Color(light: .init(red: 0.534, green: 0.331, blue: 0.0),
                                          dark: .init(red: 1.0, green: 0.624, blue: 0.039))

    /// Destructive — red, on a tint of itself. The 5xx of the set; see ``warningText``.
    ///
    /// The only one of the three whose **dark** side had to move as well. ``destructive``'s dark
    /// salmon clears its own tint on a panel at 4.55 and then misses on the two surfaces that are
    /// one step off it, reading **4.15** on a ``band`` and 4.14 on a sheet — so a 500 in the request
    /// detail's identity row was the failing case in dark mode too, not only in light.
    ///
    /// Light `(0.80, 0.10, 0.08)` → `(0.725, 0.090, 0.072)`: **5.78:1** plain on a panel, **4.72** on
    /// its own tint, **4.55** on a `band`. Dark `(1.0, 0.484, 0.453)` → `(1.0, 0.552, 0.525)`:
    /// **5.01** on its own tint on a panel and **4.57** on a `band`.
    public static let destructiveText = Color(light: .init(red: 0.725, green: 0.090, blue: 0.072),
                                              dark: .init(red: 1.0, green: 0.552, blue: 0.525))

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
    ///
    /// **Every arm is a text variant, and that is the whole point of them.** This function's result
    /// is used twice at every call site that draws a status pill — once as the label's
    /// `foregroundStyle` and once, at 12%, as the fill behind it — so whatever it returns is measured
    /// against a tint of itself rather than against the panel. On that composite ``success``,
    /// ``warning``, ``destructive`` and ``accent`` read 3.94, 3.96, 4.07 and 2.80 on a light panel;
    /// ``successText``, ``warningText`` and ``destructiveText`` read 4.72, 4.71 and 4.72, and clear
    /// the 4.5:1 floor on every surface a pill lands on in both appearances. That composite is what
    /// `DSContrastTests.statusPillTextClearsAAOnItsOwnFill` measures — driven from this function, so
    /// putting a base token back in any arm fails the suite rather than shipping.
    ///
    /// **3xx is ``accentText``, which is the one arm still short of the floor when it is filled.**
    /// The redirect blue was ``accent`` — the fill blue, the exact colour `accentText` was introduced
    /// to replace as a word, and the only arm that failed AA even *unfilled*, at 3.20 on a light
    /// panel. `accentText` takes that to 5.35, which is the reading that matters, because AGENTS.md's
    /// rule is that "only 4xx and 5xx get a fill" — a redirect is not something to stop on. Under a
    /// 12% tint of itself it reads 4.48 on a panel and 4.35 on a ``band``, so that style rule is also
    /// a contrast rule.
    ///
    /// Two call sites used to fill every code — `EndpointTrafficList.statusChip` and
    /// `RequestDetailInspector.statusPill` — and were the only reason a filled 3xx existed anywhere
    /// in the window. Both are gated on `code >= 400` now, so this arm's weakest composite is not
    /// drawn. It is left as ``accentText`` rather than pushed further down because every reading that
    /// *is* drawn clears the floor comfortably, and darkening it would move the Cancel-button blue
    /// throughout the window to fix a composite nothing renders. If a new call site ever fills a
    /// 3xx, this is the paragraph that says why it must not.
    public static func httpStatusColor(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: successText
        case 300..<400: accentText
        case 400..<500: warningText
        case 500..<600: destructiveText
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
