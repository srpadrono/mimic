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
/// number would leave the palette exactly as unchecked as it was. There are five such findings, all
/// of them in comments rather than in constants, and each is called out where it lives.
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
                (DSColors.dominant, 0.9412, 0.9725, 2.76, 10.24),
                (DSColors.surfaceElevated, 0.9373, 0.9608, 2.09, 10.22)
            ]
            case .dark: [
                (DSColors.secondary, 0.2000, 0.1725, 3.24, 10.64),
                (DSColors.dominant, 0.1686, 0.1098, 7.26, 11.31),
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

        // "the band's own step ranges 1.4–7.3" and "that rule measures ΔL* 9.9–11.3 … in both
        // appearances and on all three hosts". Both close; the second reaches 11.31 against a stated
        // 11.3, which is the same reading.
        let narrowestBand = try #require(bandSteps.min())
        let widestBand = try #require(bandSteps.max())
        let narrowestRule = try #require(ruleSteps.min())
        let widestRule = try #require(ruleSteps.max())
        #expect(narrowestBand >= 1.35)
        #expect(widestBand <= 7.30)
        #expect(narrowestRule >= 9.90)
        #expect(widestRule <= 11.35)
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

        // What the ceiling exists to protect, stated where it can fail: status text still clears AA
        // when it lands on a striped row rather than a plain one. It clears by 0.02 and 0.04.
        let amberOnStripe = try contrast(DSColors.warning, on: lightStripe, in: .light)
        let greenOnStripe = try contrast(DSColors.success, on: lightStripe, in: .light)
        #expect(isClose(amberOnStripe, 4.52, within: ratioTolerance))
        #expect(isClose(greenOnStripe, 4.54, within: ratioTolerance))
        #expect(amberOnStripe >= 4.5)
        #expect(greenOnStripe >= 4.5)

        // And why it cannot simply be deepened: at the depth AppKit's own zebra runs, both fail.
        let deepRow = grey(3.5, below: lightPanel)
        let amberOnDeepRow = try contrast(DSColors.warning, on: deepRow, in: .light)
        let greenOnDeepRow = try contrast(DSColors.success, on: deepRow, in: .light)
        #expect(isClose(amberOnDeepRow, 4.20, within: ratioTolerance))
        #expect(isClose(greenOnDeepRow, 4.22, within: ratioTolerance))
        #expect(amberOnDeepRow < 4.5)
        #expect(greenOnDeepRow < 4.5)
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
        #expect(isClose(textOnCanvas, 6.80, within: ratioTolerance))
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
    /// **Finding 5a — `warning` names the wrong surface.** "the light variant is pushed a long way
    /// down — to **4.60:1** against `dominant`". 4.60 is the reading against **`secondary`**; against
    /// `dominant` the amber measures **4.94**. The number is right and the token beside it is not,
    /// which is the more misleading of the two errors: `dominant` is the *easier* surface, so the
    /// comment understates the amber's margin on the canvas and overstates how near the floor it sits
    /// on a panel.
    ///
    /// **Finding 5b — `warning` describes a green channel the token does not have.** "Green is 0.39
    /// rather than 0.40 for one reason: 0.40 computes to 4.49:1". The constant two lines below reads
    /// **0.373**, and no surface in this palette gives 0.40 a reading of 4.49 (it is 4.63 on
    /// `dominant`, 4.32 on `secondary`). What shipped is darker than the value the paragraph names and
    /// clears AA on a panel, which 0.39 would not have — 0.39 measures 4.43 there. The three channels
    /// are asserted directly, so the token cannot quietly drift back toward the value its own comment
    /// describes.
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
        // was actually taken on.
        let amberOnPanel = try contrast(DSColors.warning, on: DSColors.secondary, in: .light)
        let greenOnPanel = try contrast(DSColors.success, on: DSColors.secondary, in: .light)
        let redOnPanel = try contrast(DSColors.destructive, on: DSColors.secondary, in: .light)
        #expect(isClose(amberOnPanel, 4.60, within: ratioTolerance))
        #expect(isClose(greenOnPanel, 4.62, within: ratioTolerance))
        #expect(isClose(redOnPanel, 4.95, within: ratioTolerance))

        // Against `dominant` — the canvas the warning comment names but did not measure.
        let amberOnCanvas = try contrast(DSColors.warning, on: DSColors.dominant, in: .light)
        let greenOnCanvas = try contrast(DSColors.success, on: DSColors.dominant, in: .light)
        let redOnCanvas = try contrast(DSColors.destructive, on: DSColors.dominant, in: .light)
        #expect(isClose(amberOnCanvas, 4.94, within: ratioTolerance))
        #expect(isClose(greenOnCanvas, 4.96, within: ratioTolerance))
        #expect(isClose(redOnCanvas, 5.31, within: ratioTolerance))

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

    // MARK: - Syntax

    /// The syntax palette states four ratios against the well it is drawn in, and is explicit that the
    /// well is the surface to measure on: `DSJSONEditor` and `DSCodeBlock` fill with `tertiary`, a
    /// step darker than the canvas, so it is the harder background. All four light figures reproduce.
    ///
    /// **Finding 6 — "The dark variants were already fine and are untouched" is not true of `key`.**
    /// Dark `Syntax.key` measures **3.97:1** on the dark `tertiary` well: under the 4.5 the same
    /// paragraph sets, and the only reading in the syntax palette that misses it in either appearance
    /// (dark `literal` is next nearest at 4.54). The light side of that token was moved to 6.48 while
    /// the dark side, never measured against the well, stayed where it was. Keys carry the most
    /// saturated hue *because* scanning a response means scanning its keys, which makes this the worst
    /// of the four for it to be.
    ///
    /// The assertion states the measured 3.97 rather than the bar, so the day somebody lightens the
    /// dark key this fails and gets updated deliberately — which is the only way a number in this file
    /// ever gets re-derived.
    @Test("Syntax colours are measured against the well they are drawn in")
    func syntaxColoursOnTheCodeWell() throws {
        let light: [(Color, Double)] = [
            (DSColors.Syntax.key, 6.48),
            (DSColors.Syntax.string, 4.87),
            (DSColors.Syntax.number, 4.66),
            (DSColors.Syntax.literal, 4.63)
        ]
        for (token, expected) in light {
            let reading = try contrast(token, on: DSColors.tertiary, in: .light)
            #expect(isClose(reading, expected, within: ratioTolerance))
            #expect(reading >= 4.5)
        }

        let dark: [(Color, Double)] = [
            (DSColors.Syntax.string, 5.55),
            (DSColors.Syntax.number, 6.30),
            (DSColors.Syntax.literal, 4.54)
        ]
        for (token, expected) in dark {
            let reading = try contrast(token, on: DSColors.tertiary, in: .dark)
            #expect(isClose(reading, expected, within: ratioTolerance))
            #expect(reading >= 4.5)
        }

        // The exception, asserted as what it is rather than as what the comment claims.
        let darkKey = try contrast(DSColors.Syntax.key, on: DSColors.tertiary, in: .dark)
        #expect(isClose(darkKey, 3.97, within: ratioTolerance))
        #expect(darkKey < 4.5)

        // "This is the same reasoning ``DSColors/accentText`` carries, and the same dark value." A
        // claim of identity is the cheapest kind to check and the easiest kind to break, because the
        // two constants sit a hundred and sixty lines apart.
        let literal = try resolve(DSColors.Syntax.literal, in: .dark)
        let accentText = try resolve(DSColors.accentText, in: .dark)
        #expect(isClose(literal.red, accentText.red, within: componentTolerance))
        #expect(isClose(literal.green, accentText.green, within: componentTolerance))
        #expect(isClose(literal.blue, accentText.blue, within: componentTolerance))
    }

    // MARK: - The structural rules AGENTS.md states

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
    @Test("Status codes map onto the semantic tokens, and the unknown range onto neither")
    func statusColoursMapToSemanticTokens() throws {
        let mapping: [(Int, Color)] = [
            (200, DSColors.success),
            (204, DSColors.success),
            (301, DSColors.accent),
            (404, DSColors.warning),
            (429, DSColors.warning),
            (500, DSColors.destructive),
            (503, DSColors.destructive)
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
