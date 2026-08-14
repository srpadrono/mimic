import AppKit
import Foundation
import SwiftUI
import Testing
import DesignSystem
@testable import AppFeatures

/// The two appearances a macOS window can be drawn in.
///
/// `nonisolated` for the reason `DSContrastTests` gives its own copy: this target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a `CaseIterable` conformance whose `allCases`
/// lands on the main actor is a witness the protocol never asked for.
private nonisolated enum Appearance: CaseIterable {
    case light
    case dark
}

/// A resolved sRGB colour, and the arithmetic every reading below is stated in.
private nonisolated struct RGBA {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// The colour as a screen would hold it — eight bits per channel. Every figure quoted in
    /// `ImportRow` is taken this way, and the last digit moves without it.
    var rendered: RGBA {
        RGBA(
            red: (red * 255).rounded() / 255,
            green: (green * 255).rounded() / 255,
            blue: (blue * 255).rounded() / 255,
            alpha: alpha
        )
    }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Source-over compositing in sRGB component space, which is what AppKit does.
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

/// What a candidate row is read against, and whether the warnings on it clear AA there.
///
/// **The row draws its own bed, which is why this suite exists rather than another sweep in
/// `DSContrastTests`.** That one measures palette tokens against palette surfaces and stops at the
/// component boundary; `ImportCandidateRow` composes three things it owns — a zebra stripe, a hover
/// wash, and a flag filled with a tint of its own ink — and until now nothing measured the result.
/// The readings that mattered were the ones nobody took: base ``DSColors/warning``, which the flags
/// and the oversized size label were drawn in, read **4.43** on the pointer's wash over the sheet
/// token and **4.23** on a panel, against a palette that holds itself to 4.5 everywhere else. On the
/// system material a sheet is really painted with it clears instead, by 0.02 at its worst — which is
/// the reason the beds below are three surfaces rather than one. A flag whose readability turns on
/// which material a sheet turns out to have is a flag measured on an assumption; the design system's
/// own suite pins the same beds from the palette's side, and the two derivations agree to a
/// hundredth on every reading they share.
///
/// Every bed here comes out of ``ImportRow/background(isHovered:rowIndex:)`` and every ink out of
/// ``ImportRow/warningInk``, so a colour changed in the view is a colour measured here. A bed list
/// hand-written into a test is the blind spot that shipped the four failures `DSContrastTests`
/// records at length, and copying it into a second suite would be that mistake with a second owner.
///
/// **The compositing helpers above are a deliberate copy.** `DSContrastTests` keeps the same
/// arithmetic and keeps it private, and a test target is a module: `MimicTests` cannot import
/// `DesignSystemTests`. The copy is held to the same authority instead — the numbers are a pure
/// function of the sRGB constants in `DSColors`, and where a reading here has a counterpart there
/// (base amber on a panel at 4.60, its self-tint at 3.96) the two agree.
@Suite("Import review row contrast")
@MainActor
struct ImportReviewRowContrastTests {
    /// Ratios are quoted to a hundredth and the eight-bit read-back can move the last digit by a few
    /// thousandths — the same tolerance, for the same reason, as the design system's own suite.
    private let ratioTolerance = 0.05

    /// One eight-bit step is 0.0039, so this checks the right code value was reached.
    private let componentTolerance = 0.001

    private func isClose(_ measured: Double, _ expected: Double, within tolerance: Double) -> Bool {
        abs(measured - expected) < tolerance
    }

    // MARK: - Resolution

    /// Resolves a token under one appearance. The conversion sits *inside*
    /// `performAsCurrentDrawingAppearance` because that is what invokes a dynamic colour's provider.
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
        let srgb = try #require(resolved, "every colour the row draws must convert to sRGB")
        return RGBA(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }

    /// The ratio a reader actually gets: the ink is flattened onto its bed before it is measured.
    private func contrast(
        _ foreground: Color,
        on background: RGBA,
        in appearance: Appearance
    ) throws -> Double {
        let ink = try resolve(foreground, in: appearance).composited(over: background)
        return contrastRatio(ink, background)
    }

    /// A label read against a fill that is a wash of the label's own colour — the "Duplicate" flag,
    /// which draws `warningInk` over `warningInk` at `flagFillOpacity`.
    private func selfTintedReading(
        _ token: Color,
        on surface: RGBA,
        in appearance: Appearance
    ) throws -> Double {
        let fill = try resolve(token.opacity(ImportRow.flagFillOpacity), in: appearance)
            .composited(over: surface)
        return try contrast(token, on: fill, in: appearance)
    }

    // MARK: - Beds

    /// The surfaces the review list can be read on, because the sheet's own material is **not** a
    /// palette token and the two files that describe it disagree.
    ///
    /// `DSContrastTests` records the system sheet material as white in light and near `#1E1E1E` in
    /// dark, measured off screen; `ImportReviewList` used to call the same surface "the elevated
    /// surface this sheet is", which is the ``DSColors/surfaceElevated`` token. They are not the same
    /// bed and the ink that survives one does not automatically survive the other — base amber on the
    /// pointer's wash reads 4.79 on the first and 4.43 on the second, which straddles the floor.
    ///
    /// So all three are measured, the panel included: it is the hardest of them, it is what the
    /// request log's identical rows sit on, and an ink that clears every one of them is an ink whose
    /// readability does not depend on settling which material a sheet turns out to have.
    private func materials(in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        let sheetMaterial: Color = switch appearance {
        case .light: .white
        case .dark: Color(nsColor: NSColor(srgbRed: 0.1176, green: 0.1176, blue: 0.1176, alpha: 1.0))
        }
        let sheet = try resolve(sheetMaterial, in: appearance)
        let elevated = try resolve(DSColors.surfaceElevated, in: appearance)
        let panel = try resolve(DSColors.secondary, in: appearance)
        return [
            ("the sheet's own material", sheet),
            ("the surfaceElevated token", elevated),
            ("a panel", panel)
        ]
    }

    /// The three fills ``ImportRow/background(isHovered:rowIndex:)`` can produce, flattened onto a
    /// material.
    ///
    /// The resting even row is the material itself: what the row draws there is *no fill*, so there
    /// is nothing to composite and `Color.clear` is not resolved for it.
    private func beds(over material: RGBA, in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        let stripe = try resolve(ImportRow.background(isHovered: false, rowIndex: 1), in: appearance)
        let hover = try resolve(ImportRow.background(isHovered: true, rowIndex: 0), in: appearance)
        return [
            ("a resting row", material),
            ("a striped row", stripe.composited(over: material)),
            ("a hovered row", hover.composited(over: material))
        ]
    }

    // MARK: - Tests

    /// Every warning on a candidate row — the "Duplicate" pill, the "Binary body" and "Body dropped"
    /// flags, and the size of a body that will be dropped — measured on every bed the row paints.
    ///
    /// The second half is the part that cannot pass vacuously: the ink this row used to draw is put
    /// back and shown failing on the beds it was failing on. That is the move `DSContrastTests` makes
    /// for every token it replaces, and the reason it makes it is that "all eighteen readings clear
    /// 4.5" is exactly the shape of assertion that stays green when the bed list is wrong.
    @Test("Every warning on a candidate row clears AA on every bed the row paints")
    func warningsOnACandidateRowClearAA() throws {
        var worst = Double.greatestFiniteMagnitude

        for appearance in Appearance.allCases {
            for material in try materials(in: appearance) {
                for bed in try beds(over: material.colour, in: appearance) {
                    let plain = try contrast(ImportRow.warningInk, on: bed.colour, in: appearance)
                    #expect(
                        plain >= 4.5,
                        "a flag on \(bed.name) over \(material.name), \(appearance): \(plain)"
                    )
                    worst = min(worst, plain)
                }
            }
        }
        // Dark, on the sheet token, under the pointer — the worst of the eighteen.
        #expect(isClose(worst, 5.69, within: ratioTolerance))

        // The ink these four used to be drawn in, put back on the bed the row paints today and on the
        // stronger wash it painted then. It clears on the kindest material and fails on the other two
        // either way, which is why this was a defect and not a judgement call about a sheet's colour.
        let replaced: [(material: String, colour: Color, onTheWash: Double, onTheOldWash: Double, clears: Bool)] = [
            ("the sheet's own material", .white, 4.79, 4.52, true),
            ("the surfaceElevated token", DSColors.surfaceElevated, 4.43, 4.17, false),
            ("a panel", DSColors.secondary, 4.23, 4.01, false)
        ]
        for entry in replaced {
            let material = try resolve(entry.colour, in: .light)
            let wash = try resolve(ImportRow.background(isHovered: true, rowIndex: 0), in: .light)
                .composited(over: material)
            let oldWash = try resolve(DSColors.accentSubtle, in: .light).composited(over: material)

            let onTheWash = try contrast(DSColors.warning, on: wash, in: .light)
            let onTheOldWash = try contrast(DSColors.warning, on: oldWash, in: .light)
            #expect(
                isClose(onTheWash, entry.onTheWash, within: ratioTolerance),
                "base amber on the wash over \(entry.material): \(onTheWash)"
            )
            #expect(
                isClose(onTheOldWash, entry.onTheOldWash, within: ratioTolerance),
                "base amber on the old wash over \(entry.material): \(onTheOldWash)"
            )
            #expect((onTheWash >= 4.5) == entry.clears)
            #expect((onTheOldWash >= 4.5) == entry.clears)
        }
    }

    /// The pointer's wash, and the two things that depend on its strength.
    ///
    /// The row used to light up with ``DSColors/accentSubtle`` at full strength — the wash
    /// `RequestLogTableRow` reserves for a **selected** row, where a hovered one gets 60% of it. Two
    /// rows in the same window saying different things with the same colour is the smaller half of
    /// the problem; the larger is that the strongest statement a row can make was being spent on the
    /// pointer passing over, in a list where selection is the entire point of the screen.
    ///
    /// It also cost contrast. The "Duplicate" flag draws its ink on a 12% tint of itself, and on a
    /// dark sheet that composite read 4.43 over the full-strength wash — the one bed in this sweep
    /// that failed. At 60% it reads 4.64.
    @Test("The pointer's wash is the weaker of the app's two, and the duplicate flag needs it to be")
    func hoverWashIsTheWeakerOfTheTwoWashes() throws {
        for appearance in Appearance.allCases {
            let hover = try resolve(ImportRow.background(isHovered: true, rowIndex: 0), in: appearance)
            let hoveredRowElsewhere = try resolve(DSColors.accentSubtle.opacity(0.6), in: appearance)
            let selectedRowElsewhere = try resolve(DSColors.accentSubtle, in: appearance)

            #expect(isClose(hover.red, hoveredRowElsewhere.red, within: componentTolerance))
            #expect(isClose(hover.green, hoveredRowElsewhere.green, within: componentTolerance))
            #expect(isClose(hover.blue, hoveredRowElsewhere.blue, within: componentTolerance))
            #expect(isClose(hover.alpha, hoveredRowElsewhere.alpha, within: componentTolerance))
            // 60% of the 12% the accent wash carries, and strictly less than the selection's.
            #expect(isClose(hover.alpha, 0.072, within: componentTolerance))
            #expect(hover.alpha < selectedRowElsewhere.alpha)

            // An odd row keeps the shared zebra rather than a wash of its own — the token four dense
            // lists in this window stripe themselves with.
            let stripe = try resolve(ImportRow.background(isHovered: false, rowIndex: 1), in: appearance)
            let token = try resolve(DSColors.rowStripe, in: appearance)
            #expect(isClose(stripe.red, token.red, within: componentTolerance))
            #expect(isClose(stripe.alpha, token.alpha, within: componentTolerance))
        }

        // The flag's fill is hand-drawn here rather than reached for from `DSStatusPill`, because a
        // word in a `Label` is not a status pill. Held to the component's number anyway, so the two
        // copies of one composite cannot drift.
        #expect(ImportRow.flagFillOpacity == DSStatusPill.fillOpacity)

        var worst = Double.greatestFiniteMagnitude
        for appearance in Appearance.allCases {
            for material in try materials(in: appearance) {
                for bed in try beds(over: material.colour, in: appearance) {
                    let pill = try selfTintedReading(ImportRow.warningInk, on: bed.colour, in: appearance)
                    #expect(
                        pill >= 4.5,
                        "the duplicate flag on \(bed.name) over \(material.name), \(appearance): \(pill)"
                    )
                    worst = min(worst, pill)
                }
            }
        }
        // Dark, on the sheet token, under the pointer — the same bed that is worst for a plain flag.
        #expect(isClose(worst, 4.64, within: ratioTolerance))

        // And that bed under the wash this row used to paint, which is where it missed.
        let darkSheet = try resolve(DSColors.surfaceElevated, in: .dark)
        let oldWash = try resolve(DSColors.accentSubtle, in: .dark).composited(over: darkSheet)
        let onTheOldWash = try selfTintedReading(ImportRow.warningInk, on: oldWash, in: .dark)
        #expect(isClose(onTheOldWash, 4.43, within: ratioTolerance))
        #expect(onTheOldWash < 4.5)
    }
}
