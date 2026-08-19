import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// The two appearances a macOS window can be drawn in. Every claim in `DSColors` is made about one of
/// them and most of the interesting ones about both.
///
/// Deliberately free of AppKit: the mapping to `NSAppearance.Name` lives in the suite, which is
/// `@MainActor`, so nothing here has to take a position on how AppKit's own isolation is annotated.
/// `nonisolated` for the same reason `DSColors` itself is — the module compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a `CaseIterable` conformance whose `allCases`
/// lands on the main actor is a witness the protocol never asked for.
private nonisolated enum Appearance: CaseIterable {
    case light
    case dark

    /// The ink a label or a rule is drawn in — black on a light window, white on a dark one. Used to
    /// assert that the alpha-only tokens stay neutral.
    var ink: Double {
        switch self {
        case .light: 0.0
        case .dark: 1.0
        }
    }
}

/// A resolved sRGB colour, and the arithmetic every claim in `DSColors` is stated in.
///
/// Alpha is deliberately not quantised: it is a compositing input, never a thing that reaches a
/// framebuffer on its own, and the rule ladder asserts it directly.
private nonisolated struct RGBA {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// The colour as a screen would hold it — eight bits per channel.
    ///
    /// **This step is what makes the file's own numbers reproduce, and it is not optional.** `band`
    /// over `secondary` in light is `0.5 × 0.910 + 0.5 × 0.941 = 0.9255`, and the doc comment quotes
    /// the host it sits on as `0.9412` where the constant two lines above reads `0.941`:
    /// 0.941 × 255 = 239.955, which is 240, which is 0.94118. Every component figure in that comment
    /// is an eight-bit value, and the ΔL\* ranges it states only close on this basis — the
    /// separator-against-band range is 9.9–11.3 rendered and 10.0–11.5 in float, and its claim that
    /// the faintest band in the window is the dark-mode one on a sheet is true rendered (1.368 against
    /// the light panel's 1.372) and false in float. "Rendered and read back in sRGB" is meant
    /// literally.
    var rendered: RGBA {
        RGBA(
            red: (red * 255).rounded() / 255,
            green: (green * 255).rounded() / 255,
            blue: (blue * 255).rounded() / 255,
            alpha: alpha
        )
    }

    /// WCAG 2.1 relative luminance. Written out rather than reached for: nothing in this project has
    /// it, and a borrowed-but-wrong one would make every number below agree with itself and with
    /// nothing else.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// CIE L\*, the perceptual lightness axis the `band` and `rowStripe` comments state their steps
    /// on. `Y` here is already the relative luminance above, so the white point is 1.
    var lStar: Double {
        let y = relativeLuminance
        let f = y > 216.0 / 24389.0 ? pow(y, 1.0 / 3.0) : (24389.0 / 27.0 * y + 16.0) / 116.0
        return 116.0 * f - 16.0
    }

    /// Source-over compositing in sRGB component space, which is what AppKit does and what the `band`
    /// comment's read-backs record: 50% `tertiary` over `secondary` lands on the exact midpoint of the
    /// two constants, not on the midpoint of their linear luminances.
    func composited(over background: RGBA) -> RGBA {
        RGBA(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1
        )
    }
}

private nonisolated func contrastRatio(_ foreground: RGBA, _ background: RGBA) -> Double {
    let a = foreground.rendered.relativeLuminance
    let b = background.rendered.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private nonisolated func deltaLStar(_ a: RGBA, _ b: RGBA) -> Double {
    abs(a.rendered.lStar - b.rendered.lStar)
}

/// The neutral grey whose L\* sits `delta` below `surface` — the inverse of `lStar`, needed for
/// exactly one claim: what a zebra stripe as strong as AppKit's would cost the amber and the green.
/// For a neutral, `Y` and the linear channel value are the same number.
private nonisolated func grey(_ delta: Double, below surface: RGBA) -> RGBA {
    let target = surface.rendered.lStar - delta
    let y = target > 8 ? pow((target + 16) / 116, 3) : target * 27 / 24389
    let channel = y <= 0.0031308 ? y * 12.92 : 1.055 * pow(y, 1 / 2.4) - 0.055
    return RGBA(red: channel, green: channel, blue: channel, alpha: 1)
}

/// `DSColors` is the most heavily documented file in this repository, and until this suite it was also
/// the least checked: roughly fifteen token pairs carry a measured WCAG ratio or a ΔL\* step in their
/// doc comment, the palette states a 4.5:1 commitment it holds itself to, and nothing anywhere
/// asserted a single one of those numbers. They are a pure function of sRGB constants, so a prose
/// figure that drifts away from the constant beside it could until now only be caught by re-deriving
/// a contrast ratio by hand — which nobody does while nudging a green channel.
///
/// Tolerances are explicit and stated per kind, because the comments quote rounded figures. Where a
/// comment's number turns out not to reproduce, the assertion states the **measured** value and the
/// discrepancy is named at the assertion and in the test's own doc comment: a test bent to fit a wrong
/// number would leave the palette exactly as unchecked as it was. Every one of those findings is in a
/// comment rather than in a constant, and each is called out where it lives — numbered, so a reader
/// can follow one back to the token it is about.
///
/// **This suite measured tokens while the window drew composites, and that gap shipped an AA
/// failure.** Every reading above the "The composite the window actually draws" mark takes a palette
/// token against a palette *surface*. Four of the colours it cleared are never drawn that way: a
/// status pill fills itself with a 12% wash of its own label colour and a method badge with a 16%
/// one, both written as a literal opacity at the call site, so the background the user sees is a
/// function of the foreground and the ratio measured here was not the ratio rendered. Under that
/// composite `success`, `warning`, `destructive` and `accent` read 3.94, 3.96, 4.07 and 2.80 on a
/// light panel against the 4.60–4.95 this file was checking, and every one of them was under the
/// floor the palette states.
///
/// The tests under that mark close it, and they are driven from the token functions —
/// `httpStatusColor(for:)` and `methodColor(for:)` — rather than from the call sites that compose
/// them, because a list of call sites copied into a test is the same blind spot moved up one level.
/// The surfaces are enumerated the same way: `pillSurfaces(in:)` is the one bed list both sweeps
/// share, and it includes the `band`, the `rowStripe`, and the hover and selection washes — the
/// places a token-only reading is most optimistic.
///
/// **Measuring a composite is not the same as measuring the *easiest* bed of it, and this suite has
/// twice done the second while claiming the first.** Four of the readings under that mark were
/// taken on the kindest surfaces the thing in question ever lands on, and all four hid a live AA
/// failure:
///
/// - The method badge was measured on a bare panel, where it read 4.50–4.54 in light. The window also
///   draws badges on a zebra stripe, on a hover wash and on a selected row — 3.97 on the last of
///   those — and the four dark hues that already failed on the *panel* were recorded and left. They
///   are fixed now.
/// - The status pill then repeated the badge's mistake with the badge's fix in plain sight: its
///   sweep ran the five palette surfaces while the badge sweep beside it ran seven, and on the two
///   washes it skipped — beds `RequestLogTableRow` demonstrably puts filled pills on — the
///   first-generation text tokens read 4.14–4.48. The text variants moved a second time for it,
///   and the two bed lists are now one list, so the sweeps cannot diverge a third time.
/// - The syntax palette was measured on `tertiary`, on the strength of a comment saying `DSJSONEditor`
///   and `DSCodeBlock` fill with it. Neither draws `DSColors.Syntax` on `tertiary` — see
///   `syntaxColoursOnTheWellTheyAreDrawnIn` — and the surface `RequestBodyView` really paints,
///   `DSColors.codeWell`, was never measured at all. Nor was the search highlight drawn on top of it,
///   which was the worst composite in the window at 2.29.
/// - `DSButton` was not measured in any state. Its white label on the primary slab reads 4.65 at rest
///   and read **3.06** while pressed, because the shade thinned the fill into the surface behind it.
///
/// The rule those three share: **enumerate the beds from the code that draws them, and assert on the
/// worst.** A single-surface reading is a claim about one screen, not about the window.
///
/// **No count of them is stated here, and one used to be.** It read "there are five" while eight
/// findings were labelled below, across six numbers — a hand-maintained mirror of a list the tests
/// beneath it already write out in full, and one that can go stale in either direction: upwards the
/// first time a finding is split into 5a/5b/5c, downwards whenever one is fixed in the palette rather
/// than only recorded here. 5a and 5b have now been fixed there, and their paragraph records what the
/// `warning` comment used to claim rather than what it still claims.
@Suite("DesignSystem colour contrast")
@MainActor
struct DSContrastTests {
    /// Contrast ratios are quoted to a hundredth in the source comments and the eight-bit read-back
    /// can move the last digit by a few thousandths. 0.05 is wide enough that rounding never fails the
    /// suite and narrow enough that a real palette change always does: the smallest deliberate step in
    /// the file — `accentFill`'s rejected candidate at 4.37 against its accepted 4.65 — is nearly six
    /// times it.
    private let ratioTolerance = 0.05

    /// ΔL\* figures are quoted to a tenth.
    private let deltaLTolerance = 0.10

    /// Components are quoted to four places and one eight-bit step is 0.0039, so this stays well
    /// inside a single code value: it checks the *right* eight-bit value was reached, not a near one.
    private let componentTolerance = 0.001

    private func isClose(_ measured: Double, _ expected: Double, within tolerance: Double) -> Bool {
        abs(measured - expected) < tolerance
    }

    // MARK: - Resolution

    /// Resolves a token under one appearance.
    ///
    /// `NSColor(Color)` hands back the dynamic colour `DSColors`' private `Color(light:dark:)` helper
    /// wrapped, and `usingColorSpace` is what invokes its provider — with whatever appearance is
    /// current, which is why the conversion sits *inside* `performAsCurrentDrawingAppearance` rather
    /// than beside it. Resolving first and switching appearance afterwards reads the same colour twice.
    private func resolve(_ color: Color, in appearance: Appearance) throws -> RGBA {
        let name: NSAppearance.Name = switch appearance {
        case .light: .aqua
        case .dark: .darkAqua
        }
        let nsAppearance = try #require(
            NSAppearance(named: name),
            "aqua and darkAqua exist on every macOS this app builds for"
        )
        var resolved: NSColor?
        nsAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let srgb = try #require(resolved, "every DSColors token must convert to sRGB")
        return RGBA(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }

    /// A translucent token flattened onto the surface it is drawn on — `band` on a panel, the hover
    /// well under a ghost button, the zebra stripe on a list row.
    private func resolve(_ color: Color, over background: Color, in appearance: Appearance) throws -> RGBA {
        let base = try resolve(background, in: appearance)
        return try resolve(color, in: appearance).composited(over: base)
    }

    /// The ratio a reader actually gets.
    ///
    /// The foreground is flattened onto the surface before it is measured, because a translucent one
    /// is not the colour it was declared as — every label tier is black or white at an alpha, and
    /// `labelPrimary` measured as pure ink rather than as 88% ink on a panel reads 21:1 where the
    /// truth is 14.8. For an opaque token the flatten is the identity, which is why it can sit in the
    /// one helper every reading goes through instead of at the call sites that happen to need it.
    private func contrast(
        _ foreground: Color,
        on background: RGBA,
        in appearance: Appearance
    ) throws -> Double {
        let ink = try resolve(foreground, in: appearance).composited(over: background)
        return contrastRatio(ink, background)
    }

    private func contrast(
        _ foreground: Color,
        on background: Color,
        in appearance: Appearance
    ) throws -> Double {
        let surface = try resolve(background, in: appearance)
        return try contrast(foreground, on: surface, in: appearance)
    }

    // MARK: - band

    /// `DSColors.band` states nine numbers: a composited read-back for each of the three surfaces a
    /// bar can sit on in each appearance, the ΔL\* step each one makes, and the range the 0.5pt
    /// `separator` closing the bar measures against it. All of them reproduce.
    ///
    /// The load-bearing claim is the last one — "the rule is the constant, the fill is the variable"
    /// — because it is what licenses the band being almost invisible in light mode instead of that
    /// reading as a bug. It holds with room: the widest band step in the window (7.26, dark mode on
    /// the editor canvas) is still a third of the narrowest rule (9.94, light mode on a panel).
    @Test("The band's step and its closing rule are the measured values, on all three hosts")
    func bandStepsAndRuleAreMeasured() throws {
        var bandSteps: [Double] = []
        var ruleSteps: [Double] = []

        for appearance in Appearance.allCases {
            // host, band read-back, host read-back, band ΔL*, separator-against-band ΔL*
            let rows: [(Color, Double, Double, Double, Double)] = switch appearance {
            case .light: [
                (DSColors.secondary, 0.9255, 0.9412, 1.37, 9.94),
                (DSColors.dominant, 0.9569, 1.0000, 3.79, 10.54),
                (DSColors.surfaceElevated, 0.9373, 0.9608, 2.09, 10.22)
            ]
            case .dark: [
                (DSColors.secondary, 0.2000, 0.1725, 3.24, 10.64),
                (DSColors.dominant, 0.1490, 0.0745, 9.28, 11.93),
                (DSColors.surfaceElevated, 0.2118, 0.2000, 1.37, 10.95)
            ]
            }

            for (host, bandRead, hostRead, bandDelta, ruleDelta) in rows {
                let surface = try resolve(host, in: appearance)
                let band = try resolve(DSColors.band, over: host, in: appearance)
                let rule = try resolve(DSColors.separator, in: appearance).composited(over: band)

                #expect(isClose(band.rendered.red, bandRead, within: componentTolerance))
                #expect(isClose(surface.rendered.red, hostRead, within: componentTolerance))

                let bandStep = deltaLStar(band, surface)
                let ruleStep = deltaLStar(rule, band)
                #expect(isClose(bandStep, bandDelta, within: deltaLTolerance))
                #expect(isClose(ruleStep, ruleDelta, within: deltaLTolerance))

                bandSteps.append(bandStep)
                ruleSteps.append(ruleStep)
            }
        }

        // The band's own step ranges 1.4–9.3, and its closing rule 9.9–11.9, in both appearances and
        // on all three hosts.
        //
        // **Both ceilings rose when the dark canvas was darkened**, from 7.30 and 11.35, and the
        // reason is worth keeping: the band is a fraction of `tertiary` laid over its host, so
        // moving a host *away* from `tertiary` widens the step without anyone touching the band. The
        // canvas moved because it is the only surface in the window whose value the app controls —
        // the navigator and the inspector are OS materials — and it had to step off them to read as
        // a separate panel at all.
        //
        // The cost is real and is recorded here rather than smoothed over: the widest band is now
        // louder than the boundary between two panels, which is the wrong way round. Quieting it is
        // not a matter of lowering the alpha, because the same alpha is what holds the narrowest
        // band above its 1.35 floor on `surfaceElevated`; it needs the band to know its host, and
        // that is its own change.
        let narrowestBand = try #require(bandSteps.min())
        let widestBand = try #require(bandSteps.max())
        let narrowestRule = try #require(ruleSteps.min())
        let widestRule = try #require(ruleSteps.max())
        #expect(narrowestBand >= 1.35)
        #expect(widestBand <= 9.30)
        #expect(narrowestRule >= 9.90)
        #expect(widestRule <= 11.95)
        #expect(widestBand < narrowestRule)

        // "the faintest band in the window is a dark-mode one, on a sheet, at ΔL* 1.4 — exactly the
        // step light mode gets on a panel". They are 1.368 and 1.372, which is one reading twice:
        // asserted as a tie rather than as an ordering, because four thousandths of a ΔL* is below
        // anything a screen resolves and a later nudge could swap which is nominally smaller.
        let darkSheetSurface = try resolve(DSColors.surfaceElevated, in: .dark)
        let darkSheetBand = try resolve(DSColors.band, over: DSColors.surfaceElevated, in: .dark)
        let lightPanelSurface = try resolve(DSColors.secondary, in: .light)
        let lightPanelBand = try resolve(DSColors.band, over: DSColors.secondary, in: .light)

        let darkSheetStep = deltaLStar(darkSheetBand, darkSheetSurface)
        let lightPanelStep = deltaLStar(lightPanelBand, lightPanelSurface)
        #expect(isClose(darkSheetStep, lightPanelStep, within: 0.05))
        #expect(isClose(darkSheetStep, 1.4, within: deltaLTolerance))
    }

    /// "Never wash the panel surface with a fraction of *itself*: `secondary.opacity(0.6)` over
    /// `secondary` is `secondary`, which is how the request log's column strip spent months being
    /// exactly the colour it was trying to differ from."
    ///
    /// That failure is invisible in source — `.opacity(0.6)` reads like a change — and it is exactly
    /// zero when measured, which makes it the one defect in this file a test catches outright rather
    /// than by threshold.
    @Test("A band is a step off its host, never a fraction of it")
    func bandIsNotAWashOfItsHost() throws {
        for appearance in Appearance.allCases {
            let panel = try resolve(DSColors.secondary, in: appearance)
            let wash = try resolve(DSColors.secondary.opacity(0.6), over: DSColors.secondary, in: appearance)
            let band = try resolve(DSColors.band, over: DSColors.secondary, in: appearance)

            #expect(deltaLStar(wash, panel) < 0.001)
            #expect(deltaLStar(band, panel) >= 1.3)
        }
    }

    // MARK: - rowStripe

    /// The zebra's value is documented as a ceiling rather than a preference, and the case for the
    /// ceiling is arithmetic: a stronger stripe spends the margin `warning` and `success` have left on
    /// a panel. Every step of that argument checks out except two of its figures.
    ///
    /// **The ceiling has changed hands twice, and both generations are asserted below.** A status
    /// code on a striped row is `warningText` or `successText` now, not `warning` or `success`, so
    /// the plain status word stopped being what the stripe was rationed for. For one wave the
    /// binding constraint was the *filled* pill, which pays the stripe's depth twice — the
    /// first-generation text tokens read 4.64–4.68 filled at this depth and fell under 4.5 by
    /// ΔL\* 1.8. Then those tokens moved again to survive a selected row (see `warningText`'s own
    /// comment), and the filled pill stopped binding anything here: the current values read
    /// 5.10–5.15 filled on the stripe and clear even AppKit's ΔL\* 3.5 at 4.76–4.82. What the
    /// ceiling falls back to is the token that set it first — the base amber clears the stripe by
    /// 0.02 and crosses under AA at ΔL\* 0.9. No row draws it on a stripe today; the import
    /// review's row flags, the last that did, are `warningText` now, so the wall is held against
    /// the token's contract rather than against a word on screen. The base readings are kept
    /// alongside because those tokens never moved; only what draws a status code did, twice.
    ///
    /// **Finding 1 — "ΔL\* 0.70 in light mode and 1.40 in dark".** Light is 0.70. Dark is **1.83**.
    /// 1.40 is what the *light* stripe measures against `dominant` (1.39), so it reads like the wrong
    /// row of a measurement table rather than a bad reading. Nothing depends on it: the paragraph's
    /// point is that the stripe is faint, and dark being wider than stated only makes the zebra more
    /// visible in the mode where it was already the stronger of the two.
    ///
    /// **Finding 2 — "at AppKit's ΔL\* 3.5 the amber falls to 4.28:1 and the green to 4.30".** At that
    /// depth they fall to **4.20** and **4.22**. The conclusion is untouched and in fact strengthened;
    /// both sit further under 4.5 than the comment claims.
    ///
    /// The AppKit figures the comment compares against (`NSColor.alternatingContentBackgroundColors`
    /// at ΔL\* 3.54 light and 5.33 dark) are deliberately **not** asserted. They are system colours:
    /// not a function of this palette, free to move between macOS releases, and pinning them here
    /// would fail this suite for something nobody in this repository can fix. The depth is taken as
    /// given; what gets measured is the consequence for our own tokens.
    @Test("The zebra stripe is the ceiling its comment says it is")
    func rowStripeIsACeiling() throws {
        let lightPanel = try resolve(DSColors.secondary, in: .light)
        let lightStripe = try resolve(DSColors.rowStripe, over: DSColors.secondary, in: .light)
        let darkPanel = try resolve(DSColors.secondary, in: .dark)
        let darkStripe = try resolve(DSColors.rowStripe, over: DSColors.secondary, in: .dark)

        #expect(isClose(lightStripe.rendered.red, 0.9333, within: componentTolerance))
        #expect(isClose(deltaLStar(lightStripe, lightPanel), 0.70, within: deltaLTolerance))

        #expect(isClose(darkStripe.rendered.red, 0.1882, within: componentTolerance))
        // The comment says 1.40. It is 1.83 — finding 1 above.
        #expect(isClose(deltaLStar(darkStripe, darkPanel), 1.83, within: deltaLTolerance))

        // "on `secondary` they clear AA with almost nothing to spare, at 4.59:1 and 4.62:1" — 4.60
        // and 4.62 rendered, the same reading for the amber and exactly the stated one for the green.
        let amberOnPanel = try contrast(DSColors.warning, on: lightPanel, in: .light)
        let greenOnPanel = try contrast(DSColors.success, on: lightPanel, in: .light)
        #expect(isClose(amberOnPanel, 4.60, within: ratioTolerance))
        #expect(isClose(greenOnPanel, 4.62, within: ratioTolerance))

        // The old ceiling, kept because `warning` and `success` did not move — only what draws a
        // status code did. Read on a striped row they clear AA by 0.02 and 0.04.
        let amberOnStripe = try contrast(DSColors.warning, on: lightStripe, in: .light)
        let greenOnStripe = try contrast(DSColors.success, on: lightStripe, in: .light)
        #expect(isClose(amberOnStripe, 4.52, within: ratioTolerance))
        #expect(isClose(greenOnStripe, 4.54, within: ratioTolerance))
        #expect(amberOnStripe >= 4.5)
        #expect(greenOnStripe >= 4.5)

        // At the depth AppKit's own zebra runs, both fail — which is what made 0.7 a ceiling while
        // these were the tokens a status code was drawn in.
        let deepRow = grey(3.5, below: lightPanel)
        let amberOnDeepRow = try contrast(DSColors.warning, on: deepRow, in: .light)
        let greenOnDeepRow = try contrast(DSColors.success, on: deepRow, in: .light)
        #expect(isClose(amberOnDeepRow, 4.20, within: ratioTolerance))
        #expect(isClose(greenOnDeepRow, 4.22, within: ratioTolerance))
        #expect(amberOnDeepRow < 4.5)
        #expect(greenOnDeepRow < 4.5)

        // The pill tokens, second generation, on the stripe. These stopped being the binding
        // constraint when they moved to survive a selected row: filled, they now clear the stripe
        // by better than half a point.
        let statusText: [(Color, Double, Double)] = [
            (DSColors.warningText, 6.12, 5.15),
            (DSColors.successText, 6.08, 5.10),
            (DSColors.destructiveText, 6.32, 5.14)
        ]
        for (token, plain, filled) in statusText {
            let bare = try contrast(token, on: lightStripe, in: .light)
            let pill = try selfTintedReading(token, on: lightStripe, in: .light)
            #expect(isClose(bare, plain, within: ratioTolerance))
            #expect(isClose(pill, filled, within: ratioTolerance))
            #expect(bare >= 4.5)
            #expect(pill >= 4.5)
        }

        // At AppKit's depth the filled pills now clear too — for one wave they were the wall here
        // (4.33–4.36 with the first-generation tokens), and the selected-row correction bought the
        // stripe this margin as a side effect. What still fails at that depth is the base amber and
        // green, asserted above at 4.20 and 4.22: the plain word is the ceiling again, crossing
        // under AA at dL* 0.9 against the stripe's current 0.7.
        let atAppKitDepth: [(Color, Double, Double)] = [
            (DSColors.warningText, 5.68, 4.82),
            (DSColors.successText, 5.64, 4.76),
            (DSColors.destructiveText, 5.86, 4.79)
        ]
        for (token, plain, filled) in atAppKitDepth {
            let bare = try contrast(token, on: deepRow, in: .light)
            let pill = try selfTintedReading(token, on: deepRow, in: .light)
            #expect(isClose(bare, plain, within: ratioTolerance))
            #expect(isClose(pill, filled, within: ratioTolerance))
            #expect(bare >= 4.5)
            #expect(pill >= 4.5)
        }

        // The crossing itself, so "dL* 0.9" above is a measured fact rather than a transcribed one:
        // one perceptual step below the current stripe the base amber still clears, and at the next
        // it does not.
        let amberAtCrossing = try contrast(DSColors.warning, on: grey(0.9, below: lightPanel), in: .light)
        let amberPastCrossing = try contrast(DSColors.warning, on: grey(1.0, below: lightPanel), in: .light)
        #expect(amberAtCrossing >= 4.5)
        #expect(amberPastCrossing < 4.5)
    }

    // MARK: - The accent as a word

    /// `accentText` exists because the system blue is a fill colour that had been pressed into
    /// labelling controls, and its comment records six readings to prove it: the shared `accent` on a
    /// panel, on a sheet and on its own hover well, then `accentText` on the same three.
    ///
    /// **What "a sheet" means, since it is not `surfaceElevated`.** The three *before* figures pin the
    /// surfaces past argument — 3.20 is `accent` on `secondary` to the third decimal, and 2.80 is
    /// `accent` on `accentSubtle` over `secondary`. The remaining 3.65 is `accent` on **white**
    /// (3.6475); against the `surfaceElevated` token it would read 3.35, which is asserted below so
    /// the distinction is recorded rather than rediscovered. The comment measured the system's sheet
    /// material, not the palette token named for sheets, and this test measures the same thing so its
    /// numbers mean what the comment means.
    ///
    /// **Finding 3 — the light panel figure is 5.35, not the stated 5.31.** Every other light reading
    /// in that comment is right to a hundredth, so this is a transcription slip rather than a
    /// different measurement, and it errs in the safe direction.
    @Test("The accent fails as text and accentText does not — light")
    func accentTextClearsAAInLight() throws {
        let panel = try resolve(DSColors.secondary, in: .light)
        let sheet = try resolve(Color.white, in: .light)
        let hoverWell = try resolve(DSColors.accentSubtle, over: DSColors.secondary, in: .light)

        // The readings that motivated the token. All three under 4.5, and the worst is the one the
        // pointer creates: a ghost button's label got *less* readable the moment you aimed at it.
        let accentOnPanel = try contrast(DSColors.accent, on: panel, in: .light)
        let accentOnSheet = try contrast(DSColors.accent, on: sheet, in: .light)
        let accentOnHover = try contrast(DSColors.accent, on: hoverWell, in: .light)
        #expect(isClose(accentOnPanel, 3.20, within: ratioTolerance))
        #expect(isClose(accentOnSheet, 3.65, within: ratioTolerance))
        #expect(isClose(accentOnHover, 2.80, within: ratioTolerance))
        for reading in [accentOnPanel, accentOnSheet, accentOnHover] {
            #expect(reading < 4.5)
        }

        // Not the token named for sheets — see the note above.
        let accentOnElevated = try contrast(DSColors.accent, on: DSColors.surfaceElevated, in: .light)
        #expect(isClose(accentOnElevated, 3.35, within: ratioTolerance))

        let textOnPanel = try contrast(DSColors.accentText, on: panel, in: .light)
        let textOnSheet = try contrast(DSColors.accentText, on: sheet, in: .light)
        let textOnHover = try contrast(DSColors.accentText, on: hoverWell, in: .light)
        // The comment says 5.31 for the panel. It is 5.35 — finding 3 above.
        #expect(isClose(textOnPanel, 5.35, within: ratioTolerance))
        #expect(isClose(textOnSheet, 6.09, within: ratioTolerance))
        #expect(isClose(textOnHover, 4.66, within: ratioTolerance))
        for reading in [textOnPanel, textOnSheet, textOnHover] {
            #expect(reading >= 4.5)
        }
    }

    /// The dark half of the same claim.
    ///
    /// **Finding 4 — none of the three dark figures reproduces.** The comment states 5.35, 6.68 and
    /// 4.79. Measured against the surfaces its light half establishes — the panel, the app's darkest
    /// surface, and the hover well over the panel — they are **5.57, 6.80 and 4.86**, each one to four
    /// percent higher. No palette surface yields 6.68 (a background near `#1E1E1E` does, which is the
    /// system's dark sheet material and outside this file), so the dark trio looks to have been taken
    /// against system chrome rather than against `DSColors`. The claim the paragraph actually makes —
    /// all three clear 4.5 — holds under either reading, and by more than stated.
    @Test("The accent fails as text and accentText does not — dark")
    func accentTextClearsAAInDark() throws {
        let panel = try resolve(DSColors.secondary, in: .dark)
        let darkestSurface = try resolve(DSColors.dominant, in: .dark)
        let hoverWell = try resolve(DSColors.accentSubtle, over: DSColors.secondary, in: .dark)

        let accentOnPanel = try contrast(DSColors.accent, on: panel, in: .dark)
        let accentOnHover = try contrast(DSColors.accent, on: hoverWell, in: .dark)
        #expect(isClose(accentOnPanel, 3.82, within: ratioTolerance))
        #expect(isClose(accentOnHover, 3.33, within: ratioTolerance))
        #expect(accentOnPanel < 4.5)
        #expect(accentOnHover < 4.5)

        let textOnPanel = try contrast(DSColors.accentText, on: panel, in: .dark)
        let textOnCanvas = try contrast(DSColors.accentText, on: darkestSurface, in: .dark)
        let textOnHover = try contrast(DSColors.accentText, on: hoverWell, in: .dark)
        #expect(isClose(textOnPanel, 5.57, within: ratioTolerance))
        // 6.80 before the canvas was darkened. A darker bed is more contrast, not less.
        #expect(isClose(textOnCanvas, 7.42, within: ratioTolerance))
        #expect(isClose(textOnHover, 4.86, within: ratioTolerance))
        for reading in [textOnPanel, textOnCanvas, textOnHover] {
            #expect(reading >= 4.5)
        }
    }

    /// `accentFill` is the opposite correction — the accent as a background with white on it — and its
    /// comment is the most precise in the file: it names the rejected candidate *and* its ratio, which
    /// makes the margin the token was chosen for directly checkable instead of a claim about taste.
    ///
    /// All four figures reproduce; 3.65 against a stated 3.64 is the same reading rendered. Both
    /// tokens carry one value for both appearances, and that is asserted too — the whole argument is
    /// about white on a slab, which does not change with the window's mode.
    @Test("Only the fill under white text moved, and it moved the smallest step that clears AA")
    func accentFillClearsAAUnderWhiteText() throws {
        for appearance in Appearance.allCases {
            // macOS's own prominent button measures the same, which is why the correction is narrow
            // rather than a bug report against Apple.
            let onAccent = try contrast(Color.white, on: DSColors.accent, in: appearance)
            #expect(isClose(onAccent, 3.65, within: ratioTolerance))
            #expect(onAccent < 4.5)

            let onFill = try contrast(Color.white, on: DSColors.accentFill, in: appearance)
            #expect(isClose(onFill, 4.65, within: ratioTolerance))
            #expect(onFill >= 4.5)

            // "(0.0, 0.46, 0.94) is 4.36 and fails" — the step not taken, and the reason the token is
            // not one notch lighter. Asserted because a candidate nobody can re-measure is a candidate
            // the next person re-proposes.
            let rejected = Color(nsColor: NSColor(srgbRed: 0.0, green: 0.46, blue: 0.94, alpha: 1.0))
            let onRejected = try contrast(Color.white, on: rejected, in: appearance)
            #expect(isClose(onRejected, 4.36, within: ratioTolerance))
            #expect(onRejected < 4.5)
        }

        // One value in both appearances, so the fills and the slabs cannot drift apart by mode.
        for token in [DSColors.accent, DSColors.accentFill] {
            let light = try resolve(token, in: .light)
            let dark = try resolve(token, in: .dark)
            #expect(isClose(light.red, dark.red, within: componentTolerance))
            #expect(isClose(light.green, dark.green, within: componentTolerance))
            #expect(isClose(light.blue, dark.blue, within: componentTolerance))
        }
    }

    // MARK: - Semantic colours

    /// `success`, `warning` and `destructive` are read as *text* before they are read as signals — a
    /// 200 in the request log, a 500 in the traffic list — which is why each carries a light variant
    /// pushed far away from its dark one, and a ratio in its comment.
    ///
    /// **Findings 5a and 5b — corrected in the token's own comment, and recorded here because that is
    /// what these assertions were built to make possible.** `warning` used to attribute its light
    /// reading — "pushed a long way down — to **4.60:1** against `dominant`" — to the wrong surface:
    /// 4.60 is the reading on **`secondary`**, and `dominant` measures **4.94**. `dominant` is the
    /// *easier* of the two, so naming it understated the amber's margin on the canvas and overstated
    /// how near the floor it sits on a panel. The same paragraph then argued "Green is 0.39 rather
    /// than 0.40" against a constant that reads **0.373**, and neither of the two values it named
    /// clears AA on a panel: 0.39 measures 4.44 there and 0.40 measures 4.32. Both surfaces and all
    /// three channels are asserted below, which is what keeps the rewritten comment checkable rather
    /// than merely newer.
    ///
    /// The `success` comment's "4.8:1" names no surface; it is the reading on `surfaceElevated`
    /// (4.83), between the panel's 4.62 and the canvas's 4.96.
    @Test("Semantic colours are readable as text on the surfaces they are drawn on")
    func semanticColoursClearAAAsText() throws {
        // The constants the warning comment argues about, pinned so the argument stays checkable.
        let amber = try resolve(DSColors.warning, in: .light)
        #expect(isClose(amber.red, 0.602, within: componentTolerance))
        #expect(isClose(amber.green, 0.373, within: componentTolerance))
        #expect(isClose(amber.blue, 0.0, within: componentTolerance))

        // Against `secondary` — the panel, the harder of the two, and the surface the comment's 4.60
        // is taken on.
        let amberOnPanel = try contrast(DSColors.warning, on: DSColors.secondary, in: .light)
        let greenOnPanel = try contrast(DSColors.success, on: DSColors.secondary, in: .light)
        let redOnPanel = try contrast(DSColors.destructive, on: DSColors.secondary, in: .light)
        #expect(isClose(amberOnPanel, 4.60, within: ratioTolerance))
        #expect(isClose(greenOnPanel, 4.62, within: ratioTolerance))
        #expect(isClose(redOnPanel, 4.95, within: ratioTolerance))

        // Against `dominant` — the canvas, the second of the two readings the warning comment now
        // states rather than the one it used to quote in place of the panel's.
        let amberOnCanvas = try contrast(DSColors.warning, on: DSColors.dominant, in: .light)
        let greenOnCanvas = try contrast(DSColors.success, on: DSColors.dominant, in: .light)
        let redOnCanvas = try contrast(DSColors.destructive, on: DSColors.dominant, in: .light)
        // 4.94 / 4.96 / 5.31 before the canvas went white. All three rose, because a lighter bed
        // is more contrast for a dark hue — the canvas is the easiest surface in the window now
        // rather than the second-easiest.
        #expect(isClose(amberOnCanvas, 5.24, within: ratioTolerance))
        #expect(isClose(greenOnCanvas, 5.26, within: ratioTolerance))
        #expect(isClose(redOnCanvas, 5.64, within: ratioTolerance))

        // `success`'s unnamed "4.8:1" and `destructive`'s unnamed "5.6:1" — the sheet token, and white.
        let white = try resolve(Color.white, in: .light)
        let greenOnSheet = try contrast(DSColors.success, on: DSColors.surfaceElevated, in: .light)
        let redOnWhite = try contrast(DSColors.destructive, on: white, in: .light)
        #expect(isClose(greenOnSheet, 4.83, within: ratioTolerance))
        #expect(isClose(redOnWhite, 5.64, within: ratioTolerance))

        // The palette's stated commitment, on both surfaces status text is ever drawn on, in both
        // appearances. `tertiary` is deliberately absent: that is the code well, where the `Syntax`
        // colours live and these three never land, and the amber measures 4.29 there.
        for appearance in Appearance.allCases {
            for surface in [DSColors.secondary, DSColors.dominant] {
                for token in [DSColors.success, DSColors.warning, DSColors.destructive] {
                    let reading = try contrast(token, on: surface, in: appearance)
                    #expect(reading >= 4.5)
                }
            }
        }
    }

    /// The "before" half of the same story: the vibrant variants that work on a near-black panel, read
    /// on a light one. That is what forced each light variant down, and both variants still exist, so
    /// it is still measurable.
    ///
    /// **Finding 5c — the green's "2.2:1" does not reproduce anywhere.** `success`'s dark variant
    /// measures **1.78** on a light panel and **2.02** against white, which is its best case. The
    /// amber's stated 2.1 *is* the reading against white (2.06). Both comments make the same point and
    /// only one quotes a number that exists — and the point itself, that a vibrant variant is
    /// unreadable in light mode by a factor of more than two, is truer than either figure suggests.
    @Test("The dark semantic variants are unreadable on a light panel, which is why the light ones moved")
    func darkSemanticVariantsFailOnLightSurfaces() throws {
        let lightPanel = try resolve(DSColors.secondary, in: .light)
        let white = try resolve(Color.white, in: .light)
        let vibrantGreen = try resolve(DSColors.success, in: .dark)
        let vibrantAmber = try resolve(DSColors.warning, in: .dark)

        let greenOnPanel = contrastRatio(vibrantGreen, lightPanel)
        let greenOnWhite = contrastRatio(vibrantGreen, white)
        let amberOnPanel = contrastRatio(vibrantAmber, lightPanel)
        let amberOnWhite = contrastRatio(vibrantAmber, white)

        // The comment says 2.2 for the green. Its best reading anywhere is 2.02.
        #expect(isClose(greenOnPanel, 1.78, within: ratioTolerance))
        #expect(isClose(greenOnWhite, 2.02, within: ratioTolerance))
        #expect(isClose(amberOnPanel, 1.81, within: ratioTolerance))
        #expect(isClose(amberOnWhite, 2.06, within: ratioTolerance))

        for reading in [greenOnPanel, greenOnWhite, amberOnPanel, amberOnWhite] {
            #expect(reading < 2.5)
        }
    }

    // MARK: - The composite the window actually draws

    /// Every surface a status pill or a method badge lands on, resolved and flattened.
    ///
    /// Seven, because that is what the window has: a panel, the editor canvas, a sheet, a
    /// ``DSColors/band``, a ``DSColors/rowStripe``, and the two accent washes a pointer or a
    /// selection paints. The band and the stripe are the beds a token-only suite forgets — the
    /// request detail's identity row takes `band` and carries a status pill on it, and three of the
    /// four lists that alternate rows draw a pill on those rows (the request log, the endpoint
    /// traffic list and the import review; the fourth is the request detail's header tables, which
    /// have no pill). The washes are the beds *this list* forgot, for one wave: this function held
    /// five entries while `RequestLogTableRow.rowBackground` painted its selected row
    /// ``DSColors/accentSubtle`` and its hovered row `accentSubtle` at 60% — with a status pill in
    /// the row — so the pill sweep was measuring every bed except the two hardest. On them the
    /// first-generation text tokens read 4.14–4.48 filled, all under the floor the sweep was
    /// holding them to on the other five. The same two washes are reached three more ways with a
    /// method badge aboard: the import review's hover, which takes the 60% one, and the
    /// `dsHoverHighlight` the sidebar and the journey step row both take at full strength. Everything
    /// here is composited onto ``DSColors/secondary``, which is the surface each composite is drawn
    /// over everywhere it appears.
    ///
    /// One bed is deliberately absent and named in `methodColor(for:)`: the sidebar is a
    /// `List(selection:)` at `.listStyle(.sidebar)`, so AppKit paints its selected row with
    /// `NSColor.selectedContentBackgroundColor` — a colour that follows the user's accent
    /// preference, and therefore a number about the machine running the test rather than about
    /// this palette. And one is deliberately not invented: a wash over ``DSColors/surfaceElevated``
    /// would read under 4.5 in dark for several hues, but the one place a washed row sits inside a
    /// sheet — the import review's hover — is drawn on the *system sheet material*, which is white
    /// in light and near `#1E1E1E` in dark (the measurement `accentTextClearsAAInDark` records),
    /// and on that material every pill and badge composite clears 4.5 with over half a point to
    /// spare. This suite's rule is to enumerate the beds from the code that draws them; a
    /// `surfaceElevated`-composited wash is a bed no screen shows.
    private func pillSurfaces(in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        let panel = try resolve(DSColors.secondary, in: appearance)
        let canvas = try resolve(DSColors.dominant, in: appearance)
        let sheet = try resolve(DSColors.surfaceElevated, in: appearance)
        let band = try resolve(DSColors.band, over: DSColors.secondary, in: appearance)
        let stripe = try resolve(DSColors.rowStripe, over: DSColors.secondary, in: appearance)
        let hovered = try resolve(DSColors.accentSubtle.opacity(0.6), in: appearance)
            .composited(over: panel)
        let selected = try resolve(DSColors.accentSubtle, in: appearance).composited(over: panel)
        return [
            ("panel", panel),
            ("canvas", canvas),
            ("sheet", sheet),
            ("band on a panel", band),
            ("striped row on a panel", stripe),
            ("hovered row on a panel", hovered),
            ("selected row on a panel", selected)
        ]
    }

    /// A label read against a fill that is *a wash of the label's own colour* — the whole defect in
    /// one function.
    ///
    /// Every status pill in the window draws `foregroundStyle(colour)` over
    /// `fill(colour.opacity(0.12))` — spelled at six call sites when this was written, spelled once
    /// now, in `DSStatusPill` — so the background is a function of the foreground and the ratio
    /// is not the one the token was chosen for. Nothing above this line could see that: the surfaces
    /// are palette tokens, the wash is a literal in the component, and the two never met in a
    /// measurement. `DSMethodBadge` does the same at 16%, which is what `alpha` is for.
    private func selfTintedReading(
        _ token: Color,
        on surface: RGBA,
        alpha: Double = 0.12,
        in appearance: Appearance
    ) throws -> Double {
        let fill = try resolve(token.opacity(alpha), in: appearance).composited(over: surface)
        return try contrast(token, on: fill, in: appearance)
    }

    /// **The failure this suite shipped, and the assertion that would have caught it.**
    ///
    /// `httpStatusColor(for:)`'s result is used twice at every call site that draws a status pill:
    /// once as the label and once, at 12%, as the fill behind it. So the thing to measure is the
    /// colour on a tint of itself, and until this test nothing did — the palette held `success`,
    /// `warning` and `destructive` to 4.5:1 against the *panel*, where they read 4.62, 4.60 and 4.95,
    /// while the window drew them at 3.94, 3.96 and 4.07.
    ///
    /// Driven from `httpStatusColor(for:)` rather than from the call sites, because a hand-copied
    /// list of call sites is the same blind spot one level up: it goes stale the moment somebody
    /// adds another. (When this test was written there were nine hand-drawn 12%-self-wash sites in
    /// `AppFeatures`; the status pills among them are one `DSStatusPill` now, which leaves the
    /// import review's duplicate flag and the drawer's unmatched-filter well drawing the composite
    /// by hand — both in `warningText`/404 amber, both covered by the sweep's 4xx arm.) The codes
    /// are the classes HTTP has, and the function is the only thing between them and a colour.
    ///
    /// 3xx is absent on purpose and has its own test below — it is the one class whose colour does
    /// not clear this bar when it is filled, and the reason is a rule about call sites rather than a
    /// missing token. The 12% here is `DSStatusPill.fillOpacity` — the component is now the one
    /// place that composite is written, and this sweep is measuring what it draws.
    ///
    /// **This sweep has already passed once while the window failed, and the bed list was how.** It
    /// ran over five surfaces while `RequestLogTableRow.rowBackground` put filled pills on a hovered
    /// and a selected row, where the tokens of the day read 4.14–4.48 — the same kindest-bed mistake
    /// the method badges made, recorded at length on `pillSurfaces(in:)`. Three guards below keep it
    /// from happening the same way twice: the two washes are pinned *into the bed list by name*, so
    /// trimming `pillSurfaces` back to five fails here rather than passing vacuously; the worst
    /// reading of the 98 is pinned, so a token change that spends the margin fails here instead of
    /// shipping; and the palette this one replaced is put back and shown failing on the bed that
    /// broke it.
    @Test("A status pill's text clears AA on the tint of itself the pill fills with")
    func statusPillTextClearsAAOnItsOwnFill() throws {
        var worst = Double.greatestFiniteMagnitude

        for appearance in Appearance.allCases {
            let surfaces = try pillSurfaces(in: appearance)

            // The two washes stay enumerated, by name. Everything else this test does is a loop
            // over `pillSurfaces`, and a loop over a list proves nothing about the list.
            let names = surfaces.map { $0.name }
            #expect(names.contains("hovered row on a panel"))
            #expect(names.contains("selected row on a panel"))

            for surface in surfaces {
                for code in [200, 204, 400, 404, 429, 500, 503] {
                    let reading = try selfTintedReading(
                        DSColors.httpStatusColor(for: code),
                        on: surface.colour,
                        in: appearance
                    )
                    #expect(
                        reading >= 4.5,
                        "\(code) on its own 12% fill, \(surface.name), \(appearance): \(reading)"
                    )
                    worst = min(worst, reading)
                }
            }
        }
        // The light green on a selected row — the floor itself plus the margin the 0.93 scale
        // bought, nothing more. (98 readings: seven codes over seven beds in two appearances.)
        #expect(isClose(worst, 4.55, within: ratioTolerance))

        // **The tokens this generation replaced, put back and measured on the bed that broke
        // them** — the exact move the badge sweep makes, for the same reason: "every reading
        // clears 4.5" is the shape that passes vacuously if the surface list is wrong. These are
        // the first-generation text variants — the values that cleared the five-bed sweep — and
        // every one of them fails on the selected row.
        let replaced: [(name: String, hue: NSColor, reading: Double)] = [
            ("successText", NSColor(srgbRed: 0.041, green: 0.433, blue: 0.166, alpha: 1.0), 4.17),
            ("warningText", NSColor(srgbRed: 0.534, green: 0.331, blue: 0.0, alpha: 1.0), 4.14),
            ("destructiveText", NSColor(srgbRed: 0.725, green: 0.090, blue: 0.072, alpha: 1.0), 4.15)
        ]
        let lightPanel = try resolve(DSColors.secondary, in: .light)
        let lightSelected = try resolve(DSColors.accentSubtle, in: .light).composited(over: lightPanel)
        for entry in replaced {
            let reading = try selfTintedReading(Color(nsColor: entry.hue), on: lightSelected, in: .light)
            #expect(isClose(reading, entry.reading, within: ratioTolerance))
            #expect(reading < 4.5, "\(entry.name) first generation, light selected: \(reading)")
        }
        // And the dark salmon's first correction, which cleared every bed but this one — here it
        // missed by 0.02.
        let darkPanel = try resolve(DSColors.secondary, in: .dark)
        let darkSelected = try resolve(DSColors.accentSubtle, in: .dark).composited(over: darkPanel)
        let firstDarkRed = try selfTintedReading(
            Color(nsColor: NSColor(srgbRed: 1.0, green: 0.552, blue: 0.525, alpha: 1.0)),
            on: darkSelected,
            in: .dark
        )
        #expect(isClose(firstDarkRed, 4.48, within: ratioTolerance))
        #expect(firstDarkRed < 4.5)
    }

    /// Why ``DSColors/successText``, ``DSColors/warningText`` and ``DSColors/destructiveText`` exist,
    /// stated as the readings that forced them.
    ///
    /// These four are what `httpStatusColor(for:)` used to return, and all four fail the test above
    /// on the easiest of its seven surfaces. Asserted as measured values rather than only as "under
    /// 4.5" so that the day one of the base tokens moves, this fails and somebody re-derives it —
    /// which is the only way a number in this file has ever been re-derived.
    ///
    /// The second half is the reading the suite *used* to take, on the bare panel, where three of the
    /// four pass. That contrast is the finding: not one of these tokens is wrong, and the palette's
    /// 4.5:1 commitment was being kept against a background the user never sees.
    @Test("The tokens the status pills used to draw fail on a tint of themselves")
    func baseSemanticTokensFailOnATintOfThemselves() throws {
        let panel = try resolve(DSColors.secondary, in: .light)

        let onATintOfThemselves: [(Color, Double)] = [
            (DSColors.success, 3.94),
            (DSColors.warning, 3.96),
            (DSColors.destructive, 4.07),
            (DSColors.accent, 2.80)
        ]
        for (token, expected) in onATintOfThemselves {
            let reading = try selfTintedReading(token, on: panel, in: .light)
            #expect(isClose(reading, expected, within: ratioTolerance))
            #expect(reading < 4.5)
        }

        // Measured the way this suite used to measure them — against the bare panel — three of the
        // four clear the floor. The accent never did, which is what `accentText` was for.
        for token in [DSColors.success, DSColors.warning, DSColors.destructive] {
            let reading = try contrast(token, on: panel, in: .light)
            #expect(reading >= 4.5)
        }
        let accentAsBareText = try contrast(DSColors.accent, on: panel, in: .light)
        #expect(accentAsBareText < 4.5)
    }

    /// The 3xx arm, which is the one `httpStatusColor(for:)` cannot lift over the floor by choosing a
    /// colour — and the reason that is acceptable.
    ///
    /// The visual standard already says a redirect gets no fill (skill `mimic-window-design`):
    /// "**A filled colour swatch is for something
    /// that needs attention.** Status codes in the traffic list are coloured text; only 4xx and 5xx
    /// get a fill." Read as text, which is what a 3xx is, `accentText` clears AA on all seven
    /// surfaces in both appearances — where ``DSColors/accent``, the fill blue this function used to
    /// return, never did at all: **3.20:1** on a light panel.
    ///
    /// Filled, it reads **4.48** on a panel and **4.35** on a band, up from 2.80 and 2.72 but still
    /// short. That is recorded here rather than fixed with a fourth blue, because nothing draws the
    /// composite: the `code >= 400` gate lives in `DSStatusPill` — the one place a pill is drawn
    /// since the six hand-drawn copies were consolidated — so a filled 3xx is unreachable in the
    /// window. The style rule turns out to be a contrast rule, and this is the measurement that
    /// says so.
    ///
    /// So this test guards a composite the window does not currently render, deliberately. It is the
    /// thing that would make re-filling a 3xx a visible mistake rather than a silent one — the two
    /// call sites were, between them, the only reason it was ever drawn, and both were written
    /// without anyone noticing they disagreed with a `pill(…isFilled: code >= 400)` in the same file.
    @Test("A redirect is readable as text, and the rule against filling one is a contrast rule")
    func redirectTextIsReadableButItsFillIsNot() throws {
        for appearance in Appearance.allCases {
            for surface in try pillSurfaces(in: appearance) {
                let reading = try contrast(
                    DSColors.httpStatusColor(for: 302),
                    on: surface.colour,
                    in: appearance
                )
                #expect(reading >= 4.5, "302 as text, \(surface.name), \(appearance): \(reading)")
            }
        }

        let panel = try resolve(DSColors.secondary, in: .light)
        let band = try resolve(DSColors.band, over: DSColors.secondary, in: .light)

        // Before and after, as bare text on a panel.
        let accentAsRedirect = try contrast(DSColors.accent, on: panel, in: .light)
        let textAsRedirect = try contrast(DSColors.httpStatusColor(for: 302), on: panel, in: .light)
        #expect(isClose(accentAsRedirect, 3.20, within: ratioTolerance))
        #expect(isClose(textAsRedirect, 5.35, within: ratioTolerance))

        // Filled — the readings that keep the house rule honest. Both improved by more than half a
        // point and both are still under; a 3xx must not be given a fill.
        let filledOnPanel = try selfTintedReading(
            DSColors.httpStatusColor(for: 302),
            on: panel,
            in: .light
        )
        let filledOnBand = try selfTintedReading(
            DSColors.httpStatusColor(for: 302),
            on: band,
            in: .light
        )
        #expect(isClose(filledOnPanel, 4.48, within: ratioTolerance))
        #expect(isClose(filledOnBand, 4.35, within: ratioTolerance))
        #expect(filledOnPanel < 4.5)
        #expect(filledOnBand < 4.5)
    }

    /// `DSMethodBadge` has the same shape as a status pill — `methodColor(for:)` as the label over a
    /// **16%** wash of itself — and this suite used to measure it on one surface and pin what it found.
    ///
    /// **What that pinning said, verbatim: "It is not fixed."** Four dark hues — `PATCH` at 3.78,
    /// `DELETE` at 3.84 and `HEAD`/`OPTIONS` at 4.04 — were asserted *as failures*, with the
    /// justification that moving six hues was a decision to take against the window. Meanwhile the
    /// seven light readings were held between 4.45 and 4.60, which reads like a pass and is a palette
    /// with no margin at all sitting on a surface it is rarely drawn on. On the bed a selected row
    /// gives it, the same hues read 3.97–4.04 in light and 3.41–4.93 in dark: twelve distinct hues,
    /// and eleven of them under the floor.
    ///
    /// The hues moved. What is asserted now is the property rather than the record — every method, on
    /// every bed in `pillSurfaces(in:)`, in both appearances, clears 4.5 — plus the worst of those 98
    /// readings, so that a future hue change that spends the margin fails here instead of shipping.
    /// (98 is seven method names over seven beds in two appearances; `HEAD` and `OPTIONS` share a hue,
    /// so 84 of them are distinct, which is the count `methodColor(for:)`'s own comment quotes.
    /// `pillSurfaces` carried five beds when the badge sweep was written and grew its own two washes
    /// here first; the pill sweep caught up a wave later, which is when the two lists became one.)
    @Test("A method badge clears AA on every bed the window puts one on")
    func methodBadgeClearsAAOnEveryBedItLandsOn() throws {
        let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
        var worst = Double.greatestFiniteMagnitude

        for appearance in Appearance.allCases {
            for surface in try pillSurfaces(in: appearance) {
                for method in methods {
                    let reading = try selfTintedReading(
                        DSColors.methodColor(for: method),
                        on: surface.colour,
                        alpha: 0.16,
                        in: appearance
                    )
                    #expect(reading >= 4.5, "\(method), \(surface.name), \(appearance): \(reading)")
                    worst = min(worst, reading)
                }
            }
        }
        // Dark `POST` on a selected row.
        #expect(isClose(worst, 4.57, within: ratioTolerance))

        // **The palette this replaced, put back and measured on the bed that broke it.** Written out
        // rather than described, so the bar above is shown rejecting the thing it was written to
        // reject — an assertion that cannot fail is this repository's most expensive recurring defect,
        // and "every reading clears 4.5" is exactly the shape that passes vacuously if the surface
        // list is wrong.
        let replaced: [(method: String, appearance: Appearance, hue: NSColor, reading: Double)] = [
            ("GET", .light, NSColor(srgbRed: 0.0, green: 0.413, blue: 0.393, alpha: 1.0), 4.04),
            ("PUT", .light, NSColor(srgbRed: 0.520, green: 0.328, blue: 0.055, alpha: 1.0), 3.97),
            ("PATCH", .light, NSColor(srgbRed: 0.505, green: 0.239, blue: 0.697, alpha: 1.0), 3.97),
            ("GET", .dark, NSColor(srgbRed: 0.259, green: 0.784, blue: 0.757, alpha: 1.0), 4.37),
            ("PATCH", .dark, NSColor(srgbRed: 0.749, green: 0.478, blue: 0.969, alpha: 1.0), 3.41),
            ("DELETE", .dark, NSColor(srgbRed: 1.0, green: 0.392, blue: 0.392, alpha: 1.0), 3.48),
            ("HEAD", .dark, NSColor(srgbRed: 0.627, green: 0.627, blue: 0.647, alpha: 1.0), 3.59)
        ]
        for entry in replaced {
            let panel = try resolve(DSColors.secondary, in: entry.appearance)
            let selected = try resolve(DSColors.accentSubtle, in: entry.appearance)
                .composited(over: panel)
            let reading = try selfTintedReading(
                Color(nsColor: entry.hue),
                on: selected,
                alpha: 0.16,
                in: entry.appearance
            )
            #expect(isClose(reading, entry.reading, within: ratioTolerance))
            #expect(reading < 4.5, "\(entry.method) \(entry.appearance) selected: \(reading)")
        }

        // No fill alpha rescues that palette, which is why the hues had to move rather than the badge
        // getting a fainter wash: on a dark selected row the worst old reading is `PATCH` at 3.41 with
        // the badge's 16% wash, and stripping the wash entirely still leaves the worst — the old
        // `DELETE` red — at 4.20.
        let darkPanel = try resolve(DSColors.secondary, in: .dark)
        let darkSelected = try resolve(DSColors.accentSubtle, in: .dark).composited(over: darkPanel)
        let unfilledDelete = try contrast(
            Color(nsColor: NSColor(srgbRed: 1.0, green: 0.392, blue: 0.392, alpha: 1.0)),
            on: darkSelected,
            in: .dark
        )
        #expect(isClose(unfilledDelete, 4.20, within: ratioTolerance))
        #expect(unfilledDelete < 4.5)

        // `PUT`'s dark amber and `Syntax.number`'s are the one pair the two palettes still share —
        // stated in `Syntax`'s own comment, and the cheapest kind of claim to check.
        let put = try resolve(DSColors.methodColor(for: "PUT"), in: .dark)
        let number = try resolve(DSColors.Syntax.number, in: .dark)
        #expect(isClose(put.red, number.red, within: componentTolerance))
        #expect(isClose(put.green, number.green, within: componentTolerance))
        #expect(isClose(put.blue, number.blue, within: componentTolerance))
    }

    // MARK: - Removed: `errorCapsuleLabelClearsAA`

    // It measured `labelPrimary` on a 16% tint of `destructive` — `DSStatusBadge`'s error capsule —
    // and recorded that the composite was safe for the reason the method badge and the status pill
    // were not: the word on it was not its fill's own hue, so the tint moved the background away
    // from the ink rather than toward it.
    //
    // The badge is gone; nothing in the window drew it. This suite's rule is to enumerate the beds
    // from the code that draws them, and a reading of a composite no screen shows is the same claim
    // about nothing that the four `DSServerState` cases were. The argument it recorded survives in
    // the pill and badge sweeps, which are about the case where the ink *is* the fill's hue and is
    // therefore the case that can fail.

    // MARK: - The bed a sheet's own list is drawn on

    /// Every surface a row of a sheet's own list lands on, resolved and flattened.
    ///
    /// `ImportReviewList` is the one list this app draws inside a sheet, and it stripes and washes
    /// its rows the way the request log does: nothing on an even row, ``DSColors/rowStripe`` on an
    /// odd one, and an accent wash under the pointer. What differs is what sits *under* all of them.
    ///
    /// It is not ``DSColors/surfaceElevated``. `pillSurfaces(in:)` says so in its own note and
    /// declines to invent a wash over that token for exactly this row; a SwiftUI sheet on macOS is
    /// drawn on the system's material — white in light, near `#1E1E1E` in dark, which is the
    /// background `accentTextClearsAAInDark` had to reach for to explain the accent comment's dark
    /// trio — and `surfaceElevated` appears nowhere in `AppFeatures`. The dark material is therefore
    /// a model rather than a token, which is why the readings taken on it below are held to the
    /// floor rather than pinned to a hundredth.
    ///
    /// **Both accent washes are here, and the pair is the point.** 60% of ``DSColors/accentSubtle``
    /// is what the request log paints under the pointer and full strength is what it reserves for a
    /// selected row, so a list that answers hover with the full wash puts its text on the harder of
    /// the two beds. Carrying both means the readings do not have to be re-derived when a list moves
    /// between them, and means the worst bed a sheet can paint is always in the sweep.
    private func sheetSurfaces(in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        let material: RGBA
        switch appearance {
        case .light: material = try resolve(Color.white, in: .light)
        case .dark: material = RGBA(red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255, alpha: 1)
        }
        let stripe = try resolve(DSColors.rowStripe, in: appearance).composited(over: material)
        let hovered = try resolve(DSColors.accentSubtle.opacity(0.6), in: appearance)
            .composited(over: material)
        let selected = try resolve(DSColors.accentSubtle, in: appearance).composited(over: material)
        return [
            ("sheet material", material),
            ("striped row on a sheet", stripe),
            ("hovered row on a sheet", hovered),
            ("selection wash on a sheet", selected)
        ]
    }

    /// **A token that clears AA on a panel can still fail on a sheet, and this is where that is
    /// asked. It is also the measurement that moved the import review's row off the base amber.**
    ///
    /// Three things on a candidate row were the base amber as plain words: the "Binary body" and
    /// "Body dropped" flags, and the size label of a response too large to bring in. The duplicate
    /// flag beside them was already `warningText` on a 12% tint of itself, for a reason its call site
    /// gave in numbers — "the base amber reads 3.96:1 on a panel and 4.11 on the elevated surface
    /// this sheet is". Both reproduce, and both are readings of the *filled* composite. The plain
    /// words were a different question, and this is where it was put.
    ///
    /// The answer is why all four take `warningText` now. On the material the sheet actually paints
    /// the plain base amber does clear — but the worst of the four beds is a row washed at selection
    /// strength, at **4.52**: 0.02 above the floor, and the smallest margin anything in this file
    /// passes on. Against the `surfaceElevated` token the same reading is **4.17**, and 4.43 even at
    /// the gentler hover strength the row settled on, so both fail. What decides that row is the
    /// choice of *surface* rather than the choice of token — and the readability of a flag should not
    /// turn on which material a sheet turns out to have. All three are pinned, so painting this sheet
    /// with the palette's sheet token has to fail here rather than be discovered on screen.
    ///
    /// The base amber is still swept as a plain word rather than dropped from the sweep, because it
    /// is still the token any plain word on a plain surface takes and a sheet is where it comes
    /// closest to failing as one.
    ///
    /// The filled arm is swept beside it because it is what decides the *token*. `warning`
    /// self-tinted reads 4.46, 4.26, 4.10 and 3.89 across the four beds and misses on every one;
    /// `warningText` clears them all with better than half a point. That is the finding the status
    /// pill's sweep made, restated on beds `pillSurfaces(in:)` does not carry.
    @Test("The amber on a sheet's own rows clears AA plain, and only warningText clears it filled")
    func amberOnASheetsOwnRows() throws {
        for appearance in Appearance.allCases {
            for bed in try sheetSurfaces(in: appearance) {
                let plain = try contrast(DSColors.warning, on: bed.colour, in: appearance)
                let word = try contrast(DSColors.warningText, on: bed.colour, in: appearance)
                let filled = try selfTintedReading(DSColors.warningText, on: bed.colour, in: appearance)
                #expect(plain >= 4.5, "plain warning, \(bed.name), \(appearance): \(plain)")
                #expect(word >= 4.5, "plain warningText, \(bed.name), \(appearance): \(word)")
                #expect(filled >= 4.5, "filled warningText, \(bed.name), \(appearance): \(filled)")
            }
        }

        // Light, where the amber has the furthest to go, pinned bed by bed in `sheetSurfaces` order.
        // The filled `warning` column is the one that fails, and it is here rather than in a comment
        // because it is the argument for the token the duplicate flag uses.
        let readings: [(bed: String, plain: Double, word: Double, filledBase: Double, filledText: Double)] = [
            ("sheet material", 5.24, 7.09, 4.46, 5.91),
            ("striped row on a sheet", 4.98, 6.74, 4.26, 5.65),
            ("hovered row on a sheet", 4.79, 6.49, 4.10, 5.44),
            ("selection wash on a sheet", 4.52, 6.13, 3.89, 5.16)
        ]
        for (index, bed) in try sheetSurfaces(in: .light).enumerated() {
            let expected = readings[index]
            #expect(bed.name == expected.bed)
            let plain = try contrast(DSColors.warning, on: bed.colour, in: .light)
            let word = try contrast(DSColors.warningText, on: bed.colour, in: .light)
            let filledBase = try selfTintedReading(DSColors.warning, on: bed.colour, in: .light)
            let filledText = try selfTintedReading(DSColors.warningText, on: bed.colour, in: .light)
            #expect(isClose(plain, expected.plain, within: ratioTolerance), "\(bed.name): \(plain)")
            #expect(isClose(word, expected.word, within: ratioTolerance), "\(bed.name): \(word)")
            #expect(isClose(filledBase, expected.filledBase, within: ratioTolerance), "\(bed.name): \(filledBase)")
            #expect(isClose(filledText, expected.filledText, within: ratioTolerance), "\(bed.name): \(filledText)")
            #expect(filledBase < 4.5, "\(bed.name): base amber survives its own tint at \(filledBase)")
        }

        // The two figures `ImportReviewList` quotes for the duplicate pill: the filled composite on a
        // panel and on the `surfaceElevated` token.
        let panel = try resolve(DSColors.secondary, in: .light)
        let sheetToken = try resolve(DSColors.surfaceElevated, in: .light)
        let filledOnPanel = try selfTintedReading(DSColors.warning, on: panel, in: .light)
        let filledOnToken = try selfTintedReading(DSColors.warning, on: sheetToken, in: .light)
        #expect(isClose(filledOnPanel, 3.96, within: ratioTolerance))
        #expect(isClose(filledOnToken, 4.11, within: ratioTolerance))

        // And the readings that say which surface this row is on, which is the distinction the whole
        // test turns on: the *plain* amber on a washed row over that same token fails at either
        // strength, where over the system material it clears at both. This pair is what moved the
        // row's three plain words onto `warningText` — a flag whose readability depends on which
        // material a sheet turns out to have is a flag drawn in the wrong ink — and it is kept so
        // that painting the sheet with the palette's sheet token still has to fail here.
        let washedToken = try resolve(DSColors.accentSubtle, over: DSColors.surfaceElevated, in: .light)
        let hoveredToken = try resolve(DSColors.accentSubtle.opacity(0.6), over: DSColors.surfaceElevated, in: .light)
        let plainOnWashedToken = try contrast(DSColors.warning, on: washedToken, in: .light)
        let plainOnHoveredToken = try contrast(DSColors.warning, on: hoveredToken, in: .light)
        #expect(isClose(plainOnWashedToken, 4.17, within: ratioTolerance))
        #expect(isClose(plainOnHoveredToken, 4.43, within: ratioTolerance))
        #expect(plainOnWashedToken < 4.5)
        #expect(plainOnHoveredToken < 4.5)
    }

    // MARK: - DSButton

    /// **A composite the window paints in every sheet, and the one this suite had never looked at.**
    ///
    /// `DSButton`'s filled variants draw a white label on a coloured slab, and `accentFill` exists
    /// precisely because white on the system blue reads 3.65. What nobody measured is the slab in the
    /// two states a pointer puts it in. `shade(_:)` returned `base.opacity(0.72)` when pressed and
    /// `0.88` when hovered — an alpha on the fill, which does not darken it, it *dissolves* it into
    /// whatever is behind the button. On a light surface that carries the slab toward the white label
    /// on top of it: the primary button, the commit action of every sheet in the app, measured
    /// **3.06:1** on the canvas while held and 3.88 while hovered, against 4.65 at rest. The comment
    /// above it said the variants "darken on press and lift very slightly on hover" — half wrong in
    /// each appearance, since thinning a fill toward a light surface lightens both states and toward a
    /// dark one darkens both.
    ///
    /// `DSButtonShade` replaces that with a wash of black *over* the slab, which is what makes this
    /// assertable at all: black over an opaque fill can only reduce luminance, so a white label's
    /// ratio can only rise, and it rises by the same amount whatever the button sits on. Three things
    /// are asserted from that — every reading clears AA, each state is at least as readable as the one
    /// before it, and the slab under the wash is opaque, which is the property the whole argument
    /// stands on.
    ///
    /// The sweep is over `DSButtonVariant.allCases` rather than a list, so a variant added without a
    /// reading fails here. That is also why `DSColors.destructiveFill` exists: white on the dark
    /// salmon `destructive` reads 2.52, and excluding the destructive variant to keep this green would
    /// be the same move as pinning the four dark method badges.
    @Test("A filled button keeps its white label above AA at rest, on hover and while pressed")
    func filledButtonsKeepTheirLabelAboveAAInEveryState() throws {
        let states: [(name: String, wash: Color)] = [
            ("at rest", DSButtonShade.wash(isPressed: false, isHovered: false)),
            ("hovered", DSButtonShade.wash(isPressed: false, isHovered: true)),
            ("pressed", DSButtonShade.wash(isPressed: true, isHovered: true))
        ]

        // The resting wash draws nothing, and says so as an alpha rather than as `.clear` — see
        // `DSButtonShade.wash`. Asserted because the three readings below are only comparable while
        // the only thing separating the states is that number.
        let atRest = try resolve(DSButtonShade.wash(isPressed: false, isHovered: false), in: .light)
        #expect(isClose(atRest.alpha, 0, within: componentTolerance))

        var filled = 0
        for appearance in Appearance.allCases {
            for variant in DSButtonVariant.allCases {
                guard let fill = variant.fill else { continue }
                filled += 1

                // The wash only stays surface-independent while the thing under it is opaque.
                let slab = try resolve(fill, in: appearance)
                #expect(isClose(slab.alpha, 1.0, within: componentTolerance), "\(variant) fill alpha")

                var previous = 0.0
                for state in states {
                    let shaded = try resolve(state.wash, in: appearance).composited(over: slab)
                    let reading = try contrast(variant.ink, on: shaded, in: appearance)
                    #expect(reading >= 4.5, "\(variant) \(state.name), \(appearance): \(reading)")
                    #expect(reading >= previous, "\(variant) \(state.name), \(appearance): \(reading)")
                    previous = reading
                }
            }
        }
        // Two filled variants, both appearances. A third arriving unmeasured is what this counts.
        #expect(filled == 4)

        // The other two carry their feedback in the fill itself — `accentSubtle` on hover,
        // `accentMuted` on press — so the black wash must not reach them, and `DSButtonStyle` gates it
        // on exactly this `nil`. The count is the assertion: a new variant is either filled, and
        // therefore swept above, or it is one of these.
        #expect(DSButtonVariant.allCases.filter { $0.fill == nil }.count == 2)

        // The six readings, stated so that spending the margin fails rather than ships.
        let expected: [(DSButtonVariant, [Double])] = [
            (.primary, [4.65, 5.17, 5.96]),
            (.destructive, [5.64, 6.21, 7.13])
        ]
        for (variant, values) in expected {
            let fill = try #require(variant.fill)
            let slab = try resolve(fill, in: .light)
            for (state, value) in zip(states, values) {
                let shaded = try resolve(state.wash, in: .light).composited(over: slab)
                let reading = try contrast(variant.ink, on: shaded, in: .light)
                #expect(
                    isClose(reading, value, within: ratioTolerance),
                    "\(variant) \(state.name): \(reading)"
                )
            }
        }

        // **The shade this replaced, reconstructed on the surface that broke it.** An alpha on the
        // fill is a function of the background, so the same button reads differently on every surface
        // in the window — and on the canvas, where the app's empty states put their call to action,
        // it fell to 3.06 under the finger.
        let canvas = try resolve(DSColors.dominant, in: .light)
        let previousShade: [(name: String, alpha: Double, reading: Double)] = [
            ("hovered", 0.88, 3.88),
            ("pressed", 0.72, 2.99)
        ]
        for entry in previousShade {
            let thinned = try resolve(DSColors.accentFill.opacity(entry.alpha), in: .light)
                .composited(over: canvas)
            let reading = try contrast(Color.white, on: thinned, in: .light)
            #expect(isClose(reading, entry.reading, within: ratioTolerance), "\(entry.name): \(reading)")
            #expect(reading < 4.5)
        }

        // White on the dark salmon, which is what `destructive` would have put on the slab. The worst
        // reading this palette has anywhere.
        let onTheSalmon = try contrast(Color.white, on: DSColors.destructive, in: .dark)
        #expect(isClose(onTheSalmon, 2.52, within: ratioTolerance))
        #expect(onTheSalmon < 4.5)
    }

    // MARK: - Syntax

    /// The four syntax hues, in the order their tokens are declared.
    private var syntaxValueTokens: [(name: String, colour: Color)] {
        [
            ("key", DSColors.Syntax.key),
            ("string", DSColors.Syntax.string),
            ("number", DSColors.Syntax.number),
            ("literal", DSColors.Syntax.literal)
        ]
    }

    /// **This test used to measure a surface no call site paints, on the strength of a comment.**
    ///
    /// `DSColors.Syntax` said its hues were "drawn inside `DSJSONEditor` and `DSCodeBlock`, whose fill
    /// is `tertiary`", and both this suite and the palette's own numbers were taken there. Two greps
    /// settle it and neither half survives them:
    ///
    /// - `grep -n 'background' Sources/DesignSystem/Components/DSJSONEditor.swift` — the editor sets
    ///   none. Its surface is its `CodeEditorView` `Theme`'s `backgroundColour`, and it colours from
    ///   that theme's own fields rather than from these tokens at all.
    /// - `grep -rn DSCodeBlock Sources Tests` — that component fills with `tertiary` and does draw
    ///   text on it, but the text is `labelPrimary`; and every hit outside its own file is a preview,
    ///   a doc comment, or a rendering test. It is placed in no feature module.
    ///
    /// The one view in the app that draws `DSColors.Syntax` is `RequestBodyView`, on
    /// `DSColors.codeWell` — a 30% wash of `tertiary`, which was a literal opacity at that call site
    /// until this wave and so could not be named by a test. That is the surface measured here, over
    /// both hosts a body view can sit on, because the view holds no opinion about its host.
    ///
    /// **What that re-pointing does to "finding 6".** The suite recorded dark `Syntax.key` at 3.97 as
    /// the palette's one AA failure and pinned it. On the well it is actually drawn in, the same token
    /// reads 5.35 over the canvas and 4.60 over a panel. The token was never the defect; the surface
    /// in the comment was.
    ///
    /// The editor's canvas is checked against the token it claims rather than assumed, which is the
    /// assertion whose absence made all of the above possible: `DSJSONEditor.lightCanvas` and
    /// `darkCanvas` are the values the component passes to its themes, and each must *be*
    /// `DSColors.dominant` for its appearance.
    @Test("Syntax colours are measured on the well they are drawn in")
    func syntaxColoursOnTheWellTheyAreDrawnIn() throws {
        let hosts: [(name: String, colour: Color)] = [
            ("canvas", DSColors.dominant),
            ("panel", DSColors.secondary)
        ]

        var worst = Double.greatestFiniteMagnitude
        for appearance in Appearance.allCases {
            for host in hosts {
                let well = try resolve(DSColors.codeWell, over: host.colour, in: appearance)
                for token in syntaxValueTokens {
                    let reading = try contrast(token.colour, on: well, in: appearance)
                    #expect(
                        reading >= 4.5,
                        "\(token.name) on the well over the \(host.name), \(appearance): \(reading)"
                    )
                    worst = min(worst, reading)
                }
            }
        }
        // Dark `key` over a panel — the token this suite used to record as a 3.97 failure on
        // `tertiary`, and the only one of the eight that comes anywhere near the floor here.
        #expect(isClose(worst, 4.60, within: ratioTolerance))

        // The eight readings `codeWell`'s own comment quotes, in declaration order, on the harder host.
        let overAPanel: [(Appearance, [Double])] = [
            (.light, [6.83, 5.13, 4.91, 4.88]),
            (.dark, [4.60, 6.44, 7.31, 5.26])
        ]
        for (appearance, expected) in overAPanel {
            let well = try resolve(DSColors.codeWell, over: DSColors.secondary, in: appearance)
            for (token, value) in zip(syntaxValueTokens, expected) {
                let reading = try contrast(token.colour, on: well, in: appearance)
                #expect(
                    isClose(reading, value, within: ratioTolerance),
                    "\(token.name) \(appearance): \(reading)"
                )
            }
        }

        // The surface the editor sets, read off the component. Without this the paragraph above is
        // exactly the kind of claim that put the old readings on `tertiary`: a comment about a
        // component, checked by nobody.
        let editorCanvases: [(Appearance, NSColor)] = [
            (.light, DSJSONEditor.lightCanvas),
            (.dark, DSJSONEditor.darkCanvas)
        ]
        for (appearance, canvas) in editorCanvases {
            let set = try resolve(Color(nsColor: canvas), in: appearance)
            let token = try resolve(DSColors.dominant, in: appearance)
            #expect(isClose(set.red, token.red, within: componentTolerance))
            #expect(isClose(set.green, token.green, within: componentTolerance))
            #expect(isClose(set.blue, token.blue, within: componentTolerance))
        }

        // …and the hues on that canvas, which is where `DSJSONEditor` now draws three of these four:
        // its theme's `stringColour`, `numberColour` and `keywordColour` are `string`, `number` and
        // `literal`. `key` goes with them because the editor's tokenizer cannot tell a JSON key from a
        // JSON string and gives keys the string colour — so this is the reading `key` would have if it
        // ever could, and the reading `RequestBodyView`'s keys would have on a well-less canvas.
        for appearance in Appearance.allCases {
            let canvas = try resolve(DSColors.dominant, in: appearance)
            for token in syntaxValueTokens {
                let reading = try contrast(token.colour, on: canvas, in: appearance)
                #expect(reading >= 4.5, "\(token.name) on the editor canvas, \(appearance): \(reading)")
            }
        }

        // "This is the same reasoning ``DSColors/accentText`` carries, and the same dark value." A
        // claim of identity is the cheapest kind to check and the easiest kind to break, because the
        // two constants sit a hundred and sixty lines apart.
        let literal = try resolve(DSColors.Syntax.literal, in: .dark)
        let accentText = try resolve(DSColors.accentText, in: .dark)
        #expect(isClose(literal.red, accentText.red, within: componentTolerance))
        #expect(isClose(literal.green, accentText.green, within: componentTolerance))
        #expect(isClose(literal.blue, accentText.blue, within: componentTolerance))
    }

    /// **The worst composite in the window, and the one nothing was measuring: a search hit.**
    ///
    /// `RequestBodyView.highlight` set `backgroundColor` to `Syntax.searchHit` — a 35% wash of
    /// `warning` — and left each run in whatever syntax colour it already had. Every reading on that
    /// bed failed, and the worst of them, dark `key` at **2.29:1**, is the lowest number anywhere in
    /// this suite. It is also the least forgivable place for one: a highlighted run is the text
    /// somebody typed a search to find, so it is the one run in the payload they are certainly trying
    /// to read.
    ///
    /// The fix is a foreground, not a paler wash. `Syntax.searchHitText` is `labelPrimary`, which is
    /// what a find highlight does in every editor — the token colour steps aside, because a found run
    /// is an answer rather than a kind of value.
    ///
    /// Both halves are asserted: the ink clears AA on the hit, and each of the four syntax hues
    /// *fails* on it. The second is the part that cannot be satisfied by accident — it is the broken
    /// version, kept, so that a change putting the syntax colour back has a test measuring exactly
    /// what that costs.
    @Test("A search hit is readable, and is only readable because it takes its own ink")
    func searchHighlightKeepsItsRunReadable() throws {
        let hosts: [(name: String, colour: Color)] = [
            ("canvas", DSColors.dominant),
            ("panel", DSColors.secondary)
        ]

        var worstInk = Double.greatestFiniteMagnitude
        var syntaxTokensClearingAA = 0
        var bestSyntax = 0.0
        for appearance in Appearance.allCases {
            for host in hosts {
                let well = try resolve(DSColors.codeWell, over: host.colour, in: appearance)
                let hit = try resolve(DSColors.Syntax.searchHit, in: appearance).composited(over: well)

                let ink = try contrast(DSColors.Syntax.searchHitText, on: hit, in: appearance)
                #expect(ink >= 4.5, "a hit over the \(host.name), \(appearance): \(ink)")
                worstInk = min(worstInk, ink)

                for token in syntaxValueTokens {
                    let reading = try contrast(token.colour, on: hit, in: appearance)
                    if reading >= 4.5 { syntaxTokensClearingAA += 1 }
                    bestSyntax = max(bestSyntax, reading)
                }
            }
        }

        // `labelPrimary` on a hit over a panel, in dark.
        #expect(isClose(worstInk, 5.52, within: ratioTolerance))

        // **The claim this case makes, restated once it stopped being absolute.**
        //
        // It used to assert every syntax hue misses AA on a hit — sixteen pairings, none clearing.
        // Making the light canvas white lifted one of them past the line: light `key` over the
        // canvas now reads 4.59 where it read 4.43, because the bed under the hit got lighter.
        //
        // The decision that `searchHitText` takes its own ink is unaffected, and asserting the count
        // rather than a per-token ceiling is what says why. A highlight cannot choose its ink per
        // token — it does not know which hue it landed on — so it has to be readable against the
        // worst of them, and fifteen of sixteen still miss. One hue clearing AA by nine hundredths
        // is not a palette you can rely on; it is the same palette with one lucky pairing.
        //
        // If this count ever rises, the question worth asking is whether the hit is still doing its
        // job as a *highlight*, not whether the ink can be dropped.
        #expect(syntaxTokensClearingAA <= 1)
        #expect(isClose(bestSyntax, 4.59, within: ratioTolerance))

        // The four readings quoted in `searchHitText`'s own comment, on the harder host.
        let onAPanel: [(Appearance, [Double])] = [
            (.light, [4.28, 3.22, 3.08, 3.06]),
            (.dark, [2.29, 3.21, 3.64, 2.62])
        ]
        for (appearance, expected) in onAPanel {
            let well = try resolve(DSColors.codeWell, over: DSColors.secondary, in: appearance)
            let hit = try resolve(DSColors.Syntax.searchHit, in: appearance).composited(over: well)
            for (token, value) in zip(syntaxValueTokens, expected) {
                let reading = try contrast(token.colour, on: hit, in: appearance)
                #expect(
                    isClose(reading, value, within: ratioTolerance),
                    "\(token.name) \(appearance): \(reading)"
                )
            }
        }
    }

    // MARK: - The structural rules the visual standard states (skill mimic-window-design)

    /// "**Nothing a user must read sits at `labelTertiary`.** It is 36% alpha — right for a timestamp
    /// or a separator, wrong for a control's own label. Unselected tab icons live at `labelSecondary`
    /// for this reason."
    ///
    /// As prose that is a habit; as contrast it is a fact about the palette, and the fact is
    /// unambiguous. On every surface in the window, in both appearances, `labelTertiary` measures
    /// between 2.45 and 3.34 — it never once reaches AA — while `labelSecondary` runs 4.55 to 5.98 and
    /// never misses it. There is no surface anywhere in this app on which the tertiary label is a
    /// legitimate choice for text, which is exactly why the rule can be absolute rather than a
    /// judgement call per site.
    ///
    /// `labelPrimary` is included for the ladder's sake: 9.18 at its worst, on the code well in dark.
    @Test("labelTertiary never reaches AA and labelSecondary never misses it")
    func labelHierarchyIsAContrastLadder() throws {
        let surfaces = [DSColors.dominant, DSColors.secondary, DSColors.tertiary, DSColors.surfaceElevated]

        for appearance in Appearance.allCases {
            for surface in surfaces {
                let primary = try contrast(DSColors.labelPrimary, on: surface, in: appearance)
                let secondary = try contrast(DSColors.labelSecondary, on: surface, in: appearance)
                let tertiary = try contrast(DSColors.labelTertiary, on: surface, in: appearance)

                #expect(primary >= 7.0)
                #expect(secondary >= 4.5)
                #expect(tertiary < 4.5)
                // And not marginally under it — this is a hierarchy tier, not a near miss.
                #expect(tertiary < 3.5)
            }

            // The alphas the rule quotes, so "36% alpha" stays a fact rather than a memory. Each is
            // pure ink, too: a label tier that picked up a tint would colour every panel it appears in.
            let tiers: [(Color, Double)] = [
                (DSColors.labelPrimary, 0.88),
                (DSColors.labelSecondary, 0.55),
                (DSColors.labelTertiary, 0.36)
            ]
            for (token, alpha) in tiers {
                let resolved = try resolve(token, in: appearance)
                #expect(isClose(resolved.alpha, alpha, within: componentTolerance))
                #expect(isClose(resolved.red, appearance.ink, within: componentTolerance))
                #expect(isClose(resolved.green, appearance.ink, within: componentTolerance))
                #expect(isClose(resolved.blue, appearance.ink, within: componentTolerance))
            }
        }
    }

    /// The rule ladder: `border` (9% light, 10% dark) under `separator` (12%) under `panelSeparator`
    /// (14%), the heaviest in the app.
    ///
    /// `panelSeparator` is the one with a measurement behind it — Xcode draws its navigator/editor and
    /// editor/inspector seams as one physical pixel compositing to 11.9% and 14.2%, and 20% was
    /// "roughly half again as heavy as the heavier of those". Those two figures are off another
    /// application's screen and are not asserted here; what is asserted is the consequence the comment
    /// draws from them, that 14% sits at the top of that band and still clears `separator`.
    ///
    /// Ordering alone would not catch the change that matters — three weights sliding together keeps
    /// every `<` true — so the values are pinned, exactly as `DSComponentRenderingTests` pins the bar,
    /// control and stroke ladders, and for the reason stated there.
    @Test("The rule ladder is border under separator under panelSeparator, at the stated weights")
    func ruleLadderIsPinned() throws {
        for appearance in Appearance.allCases {
            let border = try resolve(DSColors.border, in: appearance)
            let separator = try resolve(DSColors.separator, in: appearance)
            let panelSeparator = try resolve(DSColors.panelSeparator, in: appearance)

            #expect(isClose(border.alpha, appearance == .light ? 0.09 : 0.10, within: componentTolerance))
            #expect(isClose(separator.alpha, 0.12, within: componentTolerance))
            #expect(isClose(panelSeparator.alpha, 0.14, within: componentTolerance))

            #expect(border.alpha < separator.alpha)
            #expect(separator.alpha < panelSeparator.alpha)

            // Ink in light, light in dark. A rule that stopped being neutral would tint every seam in
            // the window at once.
            for rule in [border, separator, panelSeparator] {
                #expect(isClose(rule.red, appearance.ink, within: componentTolerance))
                #expect(isClose(rule.green, appearance.ink, within: componentTolerance))
                #expect(isClose(rule.blue, appearance.ink, within: componentTolerance))
            }
        }
    }

    /// The derivations the comments promise, checked where they can fail.
    ///
    /// Two of these are load-bearing rather than bookkeeping. `band` must derive from `tertiary` —
    /// deriving it from `secondary` is precisely the bug its own comment was written about. And
    /// "`accentSubtle` and `accentMuted` still derive from ``accent``: they are fills, and tinting them
    /// with the text blue would darken every hover well in the window to fix a contrast problem that
    /// belongs to the glyphs on top of it" — that sentence is the only thing keeping the two accent
    /// tokens from being conflated, and conflating them is a change nobody notices by reading.
    @Test("Derived tokens derive from the token their comment names")
    func derivedTokensKeepTheirBase() throws {
        func expectSameHue(_ derived: Color, _ base: Color, alpha: Double, in appearance: Appearance) throws {
            let derivedColor = try resolve(derived, in: appearance)
            let baseColor = try resolve(base, in: appearance)
            #expect(isClose(derivedColor.alpha, alpha, within: componentTolerance))
            #expect(isClose(derivedColor.red, baseColor.red, within: componentTolerance))
            #expect(isClose(derivedColor.green, baseColor.green, within: componentTolerance))
            #expect(isClose(derivedColor.blue, baseColor.blue, within: componentTolerance))
        }

        for appearance in Appearance.allCases {
            try expectSameHue(DSColors.band, DSColors.tertiary, alpha: 0.5, in: appearance)
            try expectSameHue(DSColors.rowStripe, DSColors.tertiary, alpha: 0.25, in: appearance)
            // The recipe `RequestBodyView` used to write out by hand. Pinning it here is what makes
            // `syntaxColoursOnTheWellTheyAreDrawnIn`'s bed a fact rather than a re-derivation.
            try expectSameHue(DSColors.codeWell, DSColors.tertiary, alpha: 0.3, in: appearance)
            try expectSameHue(DSColors.accentSubtle, DSColors.accent, alpha: 0.12, in: appearance)
            try expectSameHue(DSColors.accentMuted, DSColors.accent, alpha: 0.25, in: appearance)
            try expectSameHue(DSColors.Syntax.searchHit, DSColors.warning, alpha: 0.35, in: appearance)

            // Aliases: opaque, and identical to what they alias.
            try expectSameHue(DSColors.borderFocused, DSColors.accent, alpha: 1.0, in: appearance)
            try expectSameHue(DSColors.serverRunning, DSColors.success, alpha: 1.0, in: appearance)
            try expectSameHue(DSColors.serverError, DSColors.destructive, alpha: 1.0, in: appearance)
            try expectSameHue(
                DSColors.Syntax.punctuation,
                DSColors.labelTertiary,
                alpha: 0.36,
                in: appearance
            )
            try expectSameHue(
                DSColors.Syntax.searchHitText,
                DSColors.labelPrimary,
                alpha: 0.88,
                in: appearance
            )
        }
    }

    /// "**A filled colour swatch is for something that needs attention.** Status codes in the traffic
    /// list are coloured text; only 4xx and 5xx get a fill."
    ///
    /// The mapping under that rule, asserted by resolved colour rather than by `Color` equality — two
    /// dynamic colours built from different providers are not `==` even when they resolve identically,
    /// so an equality test would pass or fail for reasons unrelated to the palette. The one case that
    /// *is* written as equality is the fallback, because `.secondary` is a single shared system token
    /// on both sides and `DSComponentRenderingTests` already compares it that way.
    ///
    /// **Every arm is a text variant**, and that is load-bearing rather than cosmetic: the result is
    /// both the pill's label and, at 12%, the pill's fill, so the base tokens fail on it. See
    /// `statusPillTextClearsAAOnItsOwnFill`. This test is what stops the mapping being quietly put
    /// back — `success` and `successText` resolve to different constants in light, so a revert here
    /// fails on the component comparison as well as on the ratio.
    @Test("Status codes map onto the semantic text tokens, and the unknown range onto neither")
    func statusColoursMapToSemanticTokens() throws {
        let mapping: [(Int, Color)] = [
            (200, DSColors.successText),
            (204, DSColors.successText),
            (301, DSColors.accentText),
            (404, DSColors.warningText),
            (429, DSColors.warningText),
            (500, DSColors.destructiveText),
            (503, DSColors.destructiveText)
        ]

        for appearance in Appearance.allCases {
            for (code, expected) in mapping {
                let mapped = try resolve(DSColors.httpStatusColor(for: code), in: appearance)
                let token = try resolve(expected, in: appearance)
                #expect(isClose(mapped.red, token.red, within: componentTolerance))
                #expect(isClose(mapped.green, token.green, within: componentTolerance))
                #expect(isClose(mapped.blue, token.blue, within: componentTolerance))
            }
        }

        // Outside 200..<600 a code carries no semantic weight, so it takes the system's secondary
        // rather than borrowing a colour that means something.
        #expect(DSColors.httpStatusColor(for: 100) == .secondary)
        #expect(DSColors.httpStatusColor(for: 0) == .secondary)
    }
}
