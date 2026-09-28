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
/// **The row draws its own bed, which is why this suite exists beside `DSContrastTests`.** That one
/// measures palette roles against palette surfaces; `ImportCandidateRow` composes its own: the review
/// list sits on the content surface, odd rows add the zebra stripe, the pointer adds the hover wash,
/// and a warning note is a capsule of `warningBackground` with `ImportRow.warningInk` on it. Every bed
/// here comes out of ``ImportRow/background(isHovered:rowIndex:)`` and every ink out of
/// ``ImportRow/warningInk``, so a colour changed in the view is a colour measured here.
///
/// The warning text is 11pt, so it is held to 4.5:1, and it clears that on every bed in both
/// appearances, plain and on its chip.
///
/// **The compositing helpers above are a deliberate copy.** A test target is a module, and this one
/// cannot import `DesignSystemTests`; the numbers are a pure function of the sRGB constants in
/// `DSColors`, and where a reading here has a counterpart there the two agree.
@Suite("Import review row contrast")
@MainActor
struct ImportReviewRowContrastTests {
    /// Ratios are quoted to a hundredth and the eight-bit read-back can move the last digit.
    private let ratioTolerance = 0.05

    /// One eight-bit step is 0.0039, so this checks the right code value was reached.
    private let componentTolerance = 0.001

    private func isClose(_ measured: Double, _ expected: Double, within tolerance: Double) -> Bool {
        abs(measured - expected) < tolerance
    }

    // MARK: - Resolution

    /// Resolves a colour under one appearance. The conversion sits *inside*
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
    private func contrast(_ foreground: Color, on background: RGBA, in appearance: Appearance) throws -> Double {
        let ink = try resolve(foreground, in: appearance).composited(over: background)
        return contrastRatio(ink, background)
    }

    // MARK: - Beds

    /// The three fills ``ImportRow/background(isHovered:rowIndex:)`` can produce, flattened onto the
    /// content surface the review list is drawn on. A resting even row draws no fill, so it is the
    /// surface itself.
    private func beds(in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        let content = try resolve(DSColors.content, in: appearance)
        let stripe = try resolve(ImportRow.background(isHovered: false, rowIndex: 1), in: appearance)
        let hover = try resolve(ImportRow.background(isHovered: true, rowIndex: 0), in: appearance)
        return [
            ("a resting row", content),
            ("a striped row", stripe.composited(over: content)),
            ("a hovered row", hover.composited(over: content)),
        ]
    }

    // MARK: - Tests

    @Test("A row's fills are the palette's hover and zebra washes")
    func rowFillsAreThePalettesWashes() throws {
        #expect(ImportRow.background(isHovered: false, rowIndex: 0) == .clear)
        #expect(ImportRow.background(isHovered: false, rowIndex: 1) == DSColors.zebra)
        #expect(ImportRow.background(isHovered: true, rowIndex: 0) == DSColors.hover)
        #expect(ImportRow.background(isHovered: true, rowIndex: 1) == DSColors.hover)
        #expect(ImportRow.warningInk == DSColors.warning)

        // The pointer reads above the stripe and below an inactive selection, in both appearances.
        let expected: [Appearance: (zebra: Double, hover: Double)] = [
            .light: (0.025, 0.05),
            .dark: (0.028, 0.06),
        ]
        for appearance in Appearance.allCases {
            let reading = try #require(expected[appearance])
            let stripe = try resolve(ImportRow.background(isHovered: false, rowIndex: 1), in: appearance)
            let hover = try resolve(ImportRow.background(isHovered: true, rowIndex: 0), in: appearance)
            let selection = try resolve(DSColors.selectionInactive, in: appearance)
            #expect(isClose(stripe.alpha, reading.zebra, within: componentTolerance))
            #expect(isClose(hover.alpha, reading.hover, within: componentTolerance))
            #expect(stripe.alpha < hover.alpha)
            #expect(hover.alpha < selection.alpha)
        }
    }

    /// The size of a body that will be dropped is drawn in `warningInk` straight on the row; a note
    /// chip draws it on `warningBackground`. Both are 11pt text.
    @Test("Warnings on a candidate row are the measured values on every bed the row paints")
    func warningReadingsAreMeasured() throws {
        // bed: (plain ink, ink on the warning chip)
        let expected: [Appearance: [String: (Double, Double)]] = [
            .light: [
                "a resting row": (5.64, 5.15),
                "a striped row": (5.35, 4.91),
                "a hovered row": (5.04, 4.66),
            ],
            .dark: [
                "a resting row": (9.64, 7.58),
                "a striped row": (9.01, 6.95),
                "a hovered row": (8.14, 6.35),
            ],
        ]
        for appearance in Appearance.allCases {
            for bed in try beds(in: appearance) {
                let reading = try #require(expected[appearance]?[bed.name])
                let chip = try resolve(DSColors.warningBackground, in: appearance).composited(over: bed.colour)
                let plain = try contrast(ImportRow.warningInk, on: bed.colour, in: appearance)
                let onChip = try contrast(ImportRow.warningInk, on: chip, in: appearance)
                #expect(isClose(plain, reading.0, within: ratioTolerance), "plain on \(bed.name), \(appearance): \(plain)")
                #expect(isClose(onChip, reading.1, within: ratioTolerance), "chip on \(bed.name), \(appearance): \(onChip)")
            }
        }
    }

    @Test("Warnings clear AA on every bed the row paints, plain and on their chip")
    func warningsOnACandidateRowClearAA() throws {
        for appearance in Appearance.allCases {
            for bed in try beds(in: appearance) {
                let chip = try resolve(DSColors.warningBackground, in: appearance).composited(over: bed.colour)
                let plain = try contrast(ImportRow.warningInk, on: bed.colour, in: appearance)
                let onChip = try contrast(ImportRow.warningInk, on: chip, in: appearance)
                #expect(plain >= 4.5, "plain on \(bed.name), \(appearance): \(plain)")
                #expect(onChip >= 4.5, "chip on \(bed.name), \(appearance): \(onChip)")
            }
        }
    }

    /// A neutral note chip is `labelSecondary` on the field fill, over the same beds.
    @Test("Neutral notes clear AA on a resting row in both appearances")
    func neutralNotesClearAAAtRest() throws {
        for appearance in Appearance.allCases {
            let content = try resolve(DSColors.content, in: appearance)
            let chip = try resolve(DSColors.field, in: appearance).composited(over: content)
            let ratio = try contrast(DSColors.labelSecondary, on: chip, in: appearance)
            #expect(ratio >= 4.5, "neutral note, \(appearance): \(ratio)")
        }
    }
}
