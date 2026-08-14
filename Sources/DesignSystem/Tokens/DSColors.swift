import SwiftUI

/// Color role tokens — Ink & Electric palette.
/// Custom values give Mimic its own identity while respecting light/dark mode.
///
/// `nonisolated` because a palette has no actor affinity: these are immutable `Sendable` constants,
/// and the module's default `MainActor` isolation would otherwise put them out of reach of the
/// background work that formats a request body — which is precisely the work that must not run on
/// the main actor.
public nonisolated enum DSColors {
    // MARK: - Components

    /// One appearance's worth of a token, as sRGB components.
    ///
    /// Most of this palette is declared straight as a `Color`, which is all a SwiftUI view needs.
    /// `DSJSONEditor` is the exception: `CodeEditorView`'s `Theme` takes an `NSColor` per field and
    /// per appearance, so the editor carried its own copy of every hue as a literal — and the copies
    /// had drifted from the tokens they claimed to mirror. Its light `numberColour` was
    /// `(0.63, 0.39, 0.0)` where ``Syntax/number`` is `(0.58, 0.35, 0.0)`, and its light
    /// `keywordColour` `(0.0, 0.40, 0.85)` where ``Syntax/literal`` is `(0.0, 0.38, 0.85)`: the two
    /// values those tokens held before they were darkened. Both themes are built from the constants
    /// below now, so a hue exists once.
    ///
    /// Only the tokens that editor needs carry one. The rest of the palette has no second consumer
    /// that needs components, and writing every one of them out twice would be a cost with nothing on
    /// the other side of it.
    nonisolated struct Ink: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        func nsColor(opacity: CGFloat = 1.0) -> NSColor {
            NSColor(red: red, green: green, blue: blue, opacity: opacity)
        }
    }

    // MARK: - Surface roles (60/30/10 rule)

    /// Main window background, editor canvas
    static let dominantLightInk = Ink(red: 0.973, green: 0.973, blue: 0.980)
    static let dominantDarkInk = Ink(red: 0.110, green: 0.110, blue: 0.118)
    public static let dominant = Color(light: dominantLightInk.nsColor(),
                                       dark: dominantDarkInk.nsColor())

    /// Sidebar, inspector, toolbars — elevated surface
    static let secondaryLightInk = Ink(red: 0.941, green: 0.941, blue: 0.949)
    static let secondaryDarkInk = Ink(red: 0.173, green: 0.173, blue: 0.180)
    public static let secondary = Color(light: secondaryLightInk.nsColor(),
                                        dark: secondaryDarkInk.nsColor())

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
    /// **There is a ceiling, and which token sets it has now changed hands twice.** The original
    /// argument was that ``warning`` and ``success`` are read as text on these rows, clear AA on
    /// ``secondary`` by a hundredth, and lose that margin the moment the row darkens — so ΔL\* 0.7
    /// was the most a stripe could take. When the *text* variants took over drawing status codes,
    /// the binding constraint became the **filled** pill, which pays the stripe's depth twice — at
    /// this depth those read 4.64–4.68, crossing under 4.5 at ΔL\* 1.8. Then the pill tokens moved
    /// again, to survive a selected row's ``accentSubtle`` wash (see ``warningText``), and the
    /// margin that bought reaches the stripe too: measured on ``secondary`` in light, a status code
    /// on a striped row now reads **6.08–6.32** plain and **5.10–5.15** filled, holds AA down to
    /// ΔL\* 11.9 plain and **5.6** filled, and at AppKit's 3.5 still reads 4.76 at worst.
    ///
    /// So the ceiling belongs to the token that set it first. The base amber is still a word on
    /// these rows — the import review's "Body dropped" flag sits on its stripes — and ``warning``
    /// on a stripe reads **4.52**, clearing AA by 0.02 and crossing under it at **ΔL\* 0.9**. That
    /// is the wall: about 0.2 ΔL\* of headroom, and AppKit's depth stays out of reach until the
    /// base words stop being drawn on striped rows at all.
    ///
    /// Both generations of the ceiling are asserted in `DSContrastTests.rowStripeIsACeiling` —
    /// ``warning`` and ``success`` never moved, and the pill readings there are re-derived beside
    /// them each time the pill tokens do.
    public static let rowStripe = tertiary.opacity(0.25)

    /// The well a payload is read in — the surface ``Syntax`` is actually drawn on.
    ///
    /// It exists because the syntax palette's own comment named the wrong surface for months, and a
    /// literal opacity at one call site is what made that possible: `RequestBodyView` wrote
    /// `tertiary.opacity(0.3)` by hand, so no test could name the background the window paints. The
    /// same failure `band` and `rowStripe` were extracted for.
    ///
    /// **It is a wash, so its host is part of it.** Composited and read back in sRGB, over the editor
    /// canvas it lands on **0.9541** in light and **0.1451** in dark; over a panel, on 0.9317 and
    /// 0.1892. The request detail scrolls its body over ``dominant``, so the first pair is what the
    /// window draws today — but the view carries no opinion about its host, and the panel is the
    /// harder of the two in dark mode, so `DSContrastTests.syntaxColoursOnTheWellTheyAreDrawnIn`
    /// requires both. On the harder bed the four value hues — key, string, number, literal — read
    /// 6.83 / 5.13 / 4.91 / 4.88 in light and 4.60 / 6.44 / 7.31 / 5.26 in dark. The worst of the
    /// eight is dark ``Syntax/key`` at 4.60, and all eight clear the floor.
    ///
    /// ``Syntax/punctuation`` is ``labelTertiary`` and clears nothing anywhere, which is the point of
    /// it — braces and commas are structure you look past, not text you read.
    public static let codeWell = tertiary.opacity(0.3)

    /// Primary accent — electric blue. One value in both appearances, which is why it takes one
    /// ``Ink`` rather than a pair.
    static let accentInk = Ink(red: 0.039, green: 0.518, blue: 1.0)
    public static let accent = Color(light: accentInk.nsColor(), dark: accentInk.nsColor())

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

    /// Destructive as a *filled slab with white text on it* — the exact counterpart of ``accentFill``,
    /// and needed for the same reason one appearance at a time.
    ///
    /// `DSButton`'s destructive variant *used to* draw `.white` on ``destructive``, and this token is
    /// what it draws on now. In light the old fill was the deep red, and white on it measures
    /// **5.64:1**. In dark it was the salmon that variant shared with a 500's label — a colour chosen
    /// to be legible *as ink on a dark panel*, which is the opposite requirement — and white on it
    /// measures **2.52:1**, the worst reading anywhere in this palette.
    ///
    /// One value in both appearances, exactly as `accentFill` is, and for the argument that token
    /// already makes: white on a slab does not change with the window's mode, so a slab that has white
    /// on it should not either. Taking the light red into both keeps 5.64 on each side.
    ///
    /// This is the one correction here that no call site in the window was waiting for:
    /// `grep -rn 'variant: \.destructive' Sources` finds a single hit, in `DSComponentPreviews`. It is
    /// made anyway because `DSContrastTests.filledButtonsKeepTheirLabelAboveAAInEveryState` sweeps
    /// `DSButtonVariant.allCases`, and a variant excluded from a sweep to keep it green is the habit
    /// this wave exists to break.
    public static let destructiveFill = Color(light: .init(red: 0.80, green: 0.10, blue: 0.08),
                                              dark: .init(red: 0.80, green: 0.10, blue: 0.08))

    // MARK: - Semantic

    /// Success — green.
    ///
    /// The light variant is much darker than the dark one, and deliberately so. These are read as
    /// *text* — "Running" in the overview, the server dot beside it — and the vibrant green that
    /// works on a near-black panel measured **2.2:1** against a light one, well under the 4.5:1 AA
    /// needs for 10–11pt. The dark variant is unchanged; only the light side moved, to 4.8:1.
    ///
    /// A **200** is ``successText``: a status pill draws `httpStatusColor(for:)`'s result as its
    /// label and, when filled, as a 12% tint behind it — and though `DSStatusPill`'s gate never
    /// fills a 2xx, the sweep holds every class to the filled bar so the gate cannot silently
    /// widen. This constant reads 3.94 on that composite.
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
    /// See ``warningText`` for why these three exist and why each light variant has now moved
    /// twice; this is the 2xx of the set. ``success``'s `(0.047, 0.491, 0.189)` first became
    /// `(0.041, 0.433, 0.166)` to survive its own 12% fill on a ``band``, and that value in turn
    /// read **4.17** on the bed the first move never measured — a selected row's `accentSubtle`
    /// wash. The constant below is it scaled 0.93 toward black: **6.19:1** plain on a panel where
    /// ``success`` reads 4.62, **5.15** on its own 12% tint there, and **4.55** on the selected
    /// row, which is the worst bed a pill lands on. Dark is ``success``'s own constant, unchanged
    /// through both moves: the vibrant green reads 5.49 on its own tint on a panel and 4.85 on the
    /// selected row.
    public static let successText = Color(light: .init(red: 0.038, green: 0.403, blue: 0.154),
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
    /// own 12% fill on every surface a pill actually lands on.
    ///
    /// **"Every surface" is seven beds, and the light variants had to move twice to clear them.**
    /// The first move measured five — the panel, the canvas, a sheet, a ``band`` and a
    /// ``rowStripe`` — and stopped at the `band`, where its values read 4.55–4.59. The window also
    /// draws filled pills on the request log's hovered and selected rows
    /// (`RequestLogTableRow.rowBackground`: ``accentSubtle`` at 60% and at full strength over the
    /// panel), and on the selected row those first values read **4.14–4.17** — the same
    /// kindest-bed mistake the method badges had already been through, one component over. Each
    /// light variant below is its first value scaled 0.92–0.93 toward black, the badge fix's own
    /// method; the selected row is the binding bed, and the readings there are 4.55–4.59.
    ///
    /// The amber is the tightest of the three, for the reason ``warning`` gives: its luminance is
    /// almost all green. `(0.602, 0.373, 0.0)` became `(0.534, 0.331, 0.0)` and is now
    /// `(0.491, 0.305, 0.0)` — **6.23:1** plain on a panel, **5.21** on its own tint there,
    /// **4.59** on the selected row. Dark is ``warning``'s constant untouched through both moves;
    /// the vibrant amber reads 5.40 on its own tint on a panel and 4.84 on the selected row, so
    /// only the light side had anywhere to go. That asymmetry is the same one every other
    /// correction in this file makes — except the red's; see ``destructiveText``.
    ///
    /// ``warning`` itself is unchanged and still correct for what it is — a word on a plain surface,
    /// and the hue ``Syntax/searchHit`` is a wash of. Reach for this one when the same colour is also
    /// the fill.
    public static let warningText = Color(light: .init(red: 0.491, green: 0.305, blue: 0.0),
                                          dark: .init(red: 1.0, green: 0.624, blue: 0.039))

    /// Destructive — red, on a tint of itself. The 5xx of the set; see ``warningText``.
    ///
    /// The only one of the three whose **dark** side had to move as well — both times.
    /// ``destructive``'s dark salmon clears its own tint on a panel at 4.55 and then misses on the
    /// surfaces one step off it (**4.15** on a ``band``, 4.14 on a sheet), so the first correction
    /// lifted it to `(1.0, 0.552, 0.525)`. That value in turn read **4.48** on a dark selected
    /// row's ``accentSubtle`` wash — the failure arm of every `DSStatusPill` is this token, and a
    /// failed request's row is precisely the one that gets selected — so the dark side lifts a
    /// little further toward white, the same direction as before.
    ///
    /// Light `(0.80, 0.10, 0.08)` → `(0.725, 0.090, 0.072)` → `(0.674, 0.084, 0.067)`: **6.43:1**
    /// plain on a panel, **5.24** on its own tint there, **4.56** on the selected row. Dark
    /// `(1.0, 0.484, 0.453)` → `(1.0, 0.552, 0.525)` → `(1.0, 0.565, 0.539)`: **5.11** on its own
    /// tint on a panel, **4.66** on a `band`, **4.57** on the selected row.
    public static let destructiveText = Color(light: .init(red: 0.674, green: 0.084, blue: 0.067),
                                              dark: .init(red: 1.0, green: 0.565, blue: 0.539))

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

    /// Maps an HTTP method string to a distinct colour, readable on every bed a badge lands on.
    ///
    /// **"Selection-safe" is what this used to claim, and a selected row is precisely where it
    /// failed.** `DSMethodBadge` draws the colour this returns as its label *and*, at 16%, as the fill
    /// behind it, so the background is a function of the foreground — the same shape as a status pill,
    /// one component over. Measured that way on a bare panel the seven methods ran 4.50–4.54 in light,
    /// which is the floor itself rather than a margin, and in dark `PATCH` read 3.78, `DELETE` 3.84
    /// and `HEAD`/`OPTIONS` 4.04. Those four were *recorded* in `DSContrastTests` and left alone.
    ///
    /// A bare panel is the easiest bed a badge has. The request log stripes its rows, lights the one
    /// under the pointer with `accentSubtle` at 60%, and fills the selected one with `accentSubtle`
    /// outright — and that full-strength wash is reached three more ways, since the import review's
    /// hovered row takes it and the sidebar and the journey step row both wear it through
    /// `dsHoverHighlight`. All four of those rows carry a badge. On that bed — the worst of them,
    /// because the accent wash moves a light surface down and a dark one up — the old hues read
    /// **3.97–4.04** in light and **3.41–4.93** in dark: all six light values missed, and five of the
    /// six dark ones. No fill alpha fixes that — at 16% the dark worst is 3.41, and with *no fill at
    /// all* it is still only 4.20. The hues themselves had to move.
    ///
    /// Each light hue is its old value scaled about 0.89 toward black, and each dark one lifted toward
    /// white by between 0 and 38% — which keeps the hue and moves only the luminance. `PUT`'s dark
    /// amber is untouched: it already read 4.93 on the selected row, the only one that did. Measured
    /// after the change across seven beds (panel, canvas, sheet, stripe, hover, selected, band) in both
    /// appearances, all 84 readings clear 4.5 and the worst is **4.57** — dark `POST` on a selected
    /// row. `DSContrastTests.methodBadgeClearsAAOnEveryBedItLandsOn` holds every one of them.
    ///
    /// One bed is deliberately not asserted: the sidebar is a `List(selection:)` with
    /// `.listStyle(.sidebar)`, so its selected row is painted by AppKit with
    /// `NSColor.selectedContentBackgroundColor`, whose value follows the user's accent preference.
    /// A number pinned against that would be a fact about the machine running the test.
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
        default:                 .secondary
        }
    }

    // MARK: - Syntax colors

    /// Colors for rendering a JSON payload.
    ///
    /// Drawn from the same hue families as ``methodColor(for:)`` rather than from a stock editor
    /// theme, so a coloured body reads as part of Mimic instead of an embedded text editor. Keys carry
    /// the most saturated hue because scanning a response means scanning its keys.
    ///
    /// A method badge is three bold characters on a tinted pill; a payload is hundreds of 11pt
    /// monospaced characters, and it is the densest reading in the app. The two palettes are therefore
    /// tuned against different backgrounds and hold different values — `PUT`'s dark amber and
    /// ``number``'s are the one pair that still coincide, which
    /// `DSContrastTests.methodBadgeClearsAAOnEveryBedItLandsOn` states so that it is a fact somebody
    /// checked rather than one nobody noticed.
    ///
    /// This comment used to claim "every light variant here is darker than its `methodColor` cousin",
    /// and measured in L\* that was true of `key` alone (34.5 against `PATCH`'s 40.0) and false of
    /// `string` (42.2 against `GET`'s 39.6) and `number` (43.4 against `PUT`'s 40.2). Since the badge
    /// hues moved down to survive a selected row it is now false of all three — `GET`, `PUT` and
    /// `PATCH` sit at L\* 35.5 and only `key`, at 34.5, is darker than the badge beside it. Read the
    /// relationship as a shared hue, not as a rule about lightness.
    ///
    /// **The surface to measure against is the well the body is read in, and this comment named the
    /// wrong one.** It said these were drawn inside `DSJSONEditor` and `DSCodeBlock`, "whose fill is
    /// ``tertiary``". Neither half holds. `DSJSONEditor` sets no background at all — its surface is
    /// its `CodeEditorView` `Theme`'s `backgroundColour`, which is ``dominant`` — and it colours from
    /// that theme rather than from these tokens. `DSCodeBlock` does fill with `tertiary`, but it draws
    /// `labelPrimary` and nothing else, and in `grep -rn DSCodeBlock Sources Tests` every hit outside
    /// its own file is a preview, a doc comment, or a rendering test — it is placed in no feature
    /// module. The one place in the app that draws these tokens is `RequestBodyView`, on ``codeWell``.
    ///
    /// So the readings this paragraph used to quote — `number` at 4.00 and `literal` at 4.40 on
    /// `tertiary`, taken to 4.66 and 4.63 — were taken on a surface nothing paints. On `codeWell` the
    /// four clear 4.5 in both appearances and on either host; the token's own comment carries the
    /// eight numbers, and `DSContrastTests` requires them there rather than on `tertiary`. That move
    /// also settles the dark `key`, which the suite had recorded as the palette's one failure at 3.97
    /// on the `tertiary` well: on the well it is actually drawn in it reads 5.35 over the canvas and
    /// 4.60 over a panel.
    public enum Syntax {
        /// Object keys — the thing you actually look for in a payload.
        static let keyLightInk = Ink(red: 0.46, green: 0.14, blue: 0.70)
        static let keyDarkInk = Ink(red: 0.749, green: 0.478, blue: 0.969)
        public static let key = Color(light: keyLightInk.nsColor(), dark: keyDarkInk.nsColor())

        /// String values.
        static let stringLightInk = Ink(red: 0.0, green: 0.44, blue: 0.42)
        static let stringDarkInk = Ink(red: 0.259, green: 0.784, blue: 0.757)
        public static let string = Color(light: stringLightInk.nsColor(), dark: stringDarkInk.nsColor())

        /// Numeric values. Amber is the hardest hue to carry on a light surface — its luminance is
        /// almost all green — so the light variant is the one that had furthest to move.
        static let numberLightInk = Ink(red: 0.58, green: 0.35, blue: 0.0)
        static let numberDarkInk = Ink(red: 1.0, green: 0.694, blue: 0.306)
        public static let number = Color(light: numberLightInk.nsColor(), dark: numberDarkInk.nsColor())

        /// `true`, `false`, and `null`. Not `accent`: the shared blue is tuned for fills and
        /// selection, where it sits behind white, and reads at 3.20:1 as small text on a light panel.
        /// This is the same reasoning ``DSColors/accentText`` carries, and the same dark value.
        static let literalLightInk = Ink(red: 0.0, green: 0.38, blue: 0.85)
        static let literalDarkInk = Ink(red: 0.316, green: 0.657, blue: 1.0)
        public static let literal = Color(light: literalLightInk.nsColor(), dark: literalDarkInk.nsColor())

        /// Braces, brackets, commas, colons — structure, deliberately quiet.
        public static let punctuation = labelTertiary

        /// Background behind a search hit inside a body.
        public static let searchHit = warning.opacity(0.35)

        /// The ink a search hit is drawn in, and the whole reason a hit is legible at all.
        ///
        /// ``searchHit`` is a 35% wash of ``warning``, which is a *lot* of amber, and the highlighter
        /// used to set only the background — leaving each run in whatever syntax colour it already
        /// had. Composited and read back on `searchHit` over ``codeWell`` over a panel, those four
        /// read **4.28 / 3.22 / 3.08 / 3.06** in light and **2.29 / 3.21 / 3.64 / 2.62** in dark (key,
        /// string, number, literal). Eight readings, none of them at AA, on the one run of text
        /// somebody deliberately asked to find — and off that bed, on the bare ``codeWell``, the same
        /// four tokens read 4.60–8.49 across both hosts and both appearances. It was the highlight
        /// that failed, not the palette.
        ///
        /// ``labelPrimary`` is the answer because a found run is not a token any more, it is the
        /// answer to a question: it takes the strongest ink in the body and the syntax colour steps
        /// aside for it, which is what a find highlight does in every editor. On the same composite it
        /// reads **10.02** over the canvas and **9.68** over a panel in light, **6.11** and **5.52** in
        /// dark — the worst of the four is 5.52, better than a full point of margin.
        public static let searchHitText = labelPrimary
    }

    // MARK: - HTTP status code color

    /// Maps an HTTP status code to a semantic color.
    ///
    /// **Every arm is a text variant, and that is the whole point of them.** This function's result
    /// is used twice at every call site that draws a status pill — once as the label's
    /// `foregroundStyle` and once, at 12%, as the fill behind it — so whatever it returns is measured
    /// against a tint of itself rather than against the panel. On that composite ``success``,
    /// ``warning``, ``destructive`` and ``accent`` read 3.94, 3.96, 4.07 and 2.80 on a light panel;
    /// ``successText``, ``warningText`` and ``destructiveText`` read 5.15, 5.21 and 5.24, and clear
    /// the 4.5:1 floor on every surface a pill lands on in both appearances — seven beds, the
    /// request log's hovered and selected rows included, which are the ones that forced each text
    /// variant's second move (worst reading: 4.55, the green on a light selected row). That
    /// composite is what `DSContrastTests.statusPillTextClearsAAOnItsOwnFill` measures — driven
    /// from this function, so putting a base token back in any arm fails the suite rather than
    /// shipping.
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
    /// in the window. The `code >= 400` gate that stopped them lives in `DSStatusPill` now, the one
    /// place a status pill is drawn since the six hand-copied ones were consolidated, so this arm's
    /// weakest composite is not drawn. It is left as ``accentText`` rather than pushed further down
    /// because every reading that *is* drawn clears the floor comfortably, and darkening it would
    /// move the Cancel-button blue throughout the window to fix a composite nothing renders. If the
    /// component's gate is ever widened to fill a 3xx, this is the paragraph that says why it must
    /// not be.
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
