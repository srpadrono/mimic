import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

private nonisolated enum Appearance: CaseIterable {
    case light
    case dark

    var ink: Double {
        switch self {
        case .light: 0.0
        case .dark: 1.0
        }
    }
}

/// sRGB source-over compositing over opaque surfaces, quantized to 8-bit output.
private nonisolated struct RGBA {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var rendered: RGBA {
        RGBA(
            red: (red * 255).rounded() / 255,
            green: (green * 255).rounded() / 255,
            blue: (blue * 255).rounded() / 255,
            alpha: alpha
        )
    }

    // WCAG relative luminance with the sRGB transfer function.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var lStar: Double {
        let y = relativeLuminance
        let f = y > 216.0 / 24389.0 ? pow(y, 1.0 / 3.0) : (24389.0 / 27.0 * y + 16.0) / 116.0
        return 116.0 * f - 16.0
    }

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

// Inverse CIE L* for comparing a controlled stripe depth against a palette surface.
private nonisolated func grey(_ delta: Double, below surface: RGBA) -> RGBA {
    let target = surface.rendered.lStar - delta
    let y = target > 8 ? pow((target + 16) / 116, 3) : target * 27 / 24389
    let channel = y <= 0.0031308 ? y * 12.92 : 1.055 * pow(y, 1 / 2.4) - 0.055
    return RGBA(red: channel, green: channel, blue: channel, alpha: 1)
}

/// Measures text after all translucent fills and inks are composited.
/// Native material fixtures are representative samples, not guarantees about every OS appearance.
@Suite("DesignSystem colour contrast")
@MainActor
struct DSContrastTests {
    private let ratioTolerance = 0.05

    private let deltaLTolerance = 0.10

    private let componentTolerance = 0.001

    private func isClose(_ measured: Double, _ expected: Double, within tolerance: Double) -> Bool {
        abs(measured - expected) < tolerance
    }

    // Resolve inside the drawing appearance so dynamic colors actually switch variants.
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

    private func resolve(_ color: Color, over background: Color, in appearance: Appearance) throws -> RGBA {
        let base = try resolve(background, in: appearance)
        return try resolve(color, in: appearance).composited(over: base)
    }

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

    @Test("The band's step and its closing rule are the measured values, on all three hosts")
    func bandStepsAndRuleAreMeasured() throws {
        var bandSteps: [Double] = []
        var ruleSteps: [Double] = []

        for appearance in Appearance.allCases {
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

        let narrowestBand = try #require(bandSteps.min())
        let widestBand = try #require(bandSteps.max())
        let narrowestRule = try #require(ruleSteps.min())
        let widestRule = try #require(ruleSteps.max())
        #expect(narrowestBand >= 1.35)
        #expect(widestBand <= 9.30)
        #expect(narrowestRule >= 9.90)
        #expect(widestRule <= 11.95)
        #expect(widestBand < narrowestRule)

        let darkSheetSurface = try resolve(DSColors.surfaceElevated, in: .dark)
        let darkSheetBand = try resolve(DSColors.band, over: DSColors.surfaceElevated, in: .dark)
        let lightPanelSurface = try resolve(DSColors.secondary, in: .light)
        let lightPanelBand = try resolve(DSColors.band, over: DSColors.secondary, in: .light)

        let darkSheetStep = deltaLStar(darkSheetBand, darkSheetSurface)
        let lightPanelStep = deltaLStar(lightPanelBand, lightPanelSurface)
        #expect(isClose(darkSheetStep, lightPanelStep, within: 0.05))
        #expect(isClose(darkSheetStep, 1.4, within: deltaLTolerance))
    }

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

    @Test("The zebra stripe is the ceiling its comment says it is")
    func rowStripeIsACeiling() throws {
        let lightPanel = try resolve(DSColors.secondary, in: .light)
        let lightStripe = try resolve(DSColors.rowStripe, over: DSColors.secondary, in: .light)
        let darkPanel = try resolve(DSColors.secondary, in: .dark)
        let darkStripe = try resolve(DSColors.rowStripe, over: DSColors.secondary, in: .dark)

        #expect(isClose(lightStripe.rendered.red, 0.9333, within: componentTolerance))
        #expect(isClose(deltaLStar(lightStripe, lightPanel), 0.70, within: deltaLTolerance))

        #expect(isClose(darkStripe.rendered.red, 0.1882, within: componentTolerance))
        #expect(isClose(deltaLStar(darkStripe, darkPanel), 1.83, within: deltaLTolerance))

        let amberOnPanel = try contrast(DSColors.warning, on: lightPanel, in: .light)
        let greenOnPanel = try contrast(DSColors.success, on: lightPanel, in: .light)
        #expect(isClose(amberOnPanel, 4.60, within: ratioTolerance))
        #expect(isClose(greenOnPanel, 4.62, within: ratioTolerance))

        let amberOnStripe = try contrast(DSColors.warning, on: lightStripe, in: .light)
        let greenOnStripe = try contrast(DSColors.success, on: lightStripe, in: .light)
        #expect(isClose(amberOnStripe, 4.52, within: ratioTolerance))
        #expect(isClose(greenOnStripe, 4.54, within: ratioTolerance))
        #expect(amberOnStripe >= 4.5)
        #expect(greenOnStripe >= 4.5)

        let deepRow = grey(3.5, below: lightPanel)
        let amberOnDeepRow = try contrast(DSColors.warning, on: deepRow, in: .light)
        let greenOnDeepRow = try contrast(DSColors.success, on: deepRow, in: .light)
        #expect(isClose(amberOnDeepRow, 4.20, within: ratioTolerance))
        #expect(isClose(greenOnDeepRow, 4.22, within: ratioTolerance))
        #expect(amberOnDeepRow < 4.5)
        #expect(greenOnDeepRow < 4.5)

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

        let amberAtCrossing = try contrast(DSColors.warning, on: grey(0.9, below: lightPanel), in: .light)
        let amberPastCrossing = try contrast(DSColors.warning, on: grey(1.0, below: lightPanel), in: .light)
        #expect(amberAtCrossing >= 4.5)
        #expect(amberPastCrossing < 4.5)
    }

    @Test("The accent fails as text and accentText does not — light")
    func accentTextClearsAAInLight() throws {
        let panel = try resolve(DSColors.secondary, in: .light)
        let sheet = try resolve(Color.white, in: .light)
        let hoverWell = try resolve(DSColors.accentSubtle, over: DSColors.secondary, in: .light)

        let accentOnPanel = try contrast(DSColors.accent, on: panel, in: .light)
        let accentOnSheet = try contrast(DSColors.accent, on: sheet, in: .light)
        let accentOnHover = try contrast(DSColors.accent, on: hoverWell, in: .light)
        #expect(isClose(accentOnPanel, 3.20, within: ratioTolerance))
        #expect(isClose(accentOnSheet, 3.65, within: ratioTolerance))
        #expect(isClose(accentOnHover, 2.80, within: ratioTolerance))
        for reading in [accentOnPanel, accentOnSheet, accentOnHover] {
            #expect(reading < 4.5)
        }

        let accentOnElevated = try contrast(DSColors.accent, on: DSColors.surfaceElevated, in: .light)
        #expect(isClose(accentOnElevated, 3.35, within: ratioTolerance))

        let textOnPanel = try contrast(DSColors.accentText, on: panel, in: .light)
        let textOnSheet = try contrast(DSColors.accentText, on: sheet, in: .light)
        let textOnHover = try contrast(DSColors.accentText, on: hoverWell, in: .light)
        #expect(isClose(textOnPanel, 5.35, within: ratioTolerance))
        #expect(isClose(textOnSheet, 6.09, within: ratioTolerance))
        #expect(isClose(textOnHover, 4.66, within: ratioTolerance))
        for reading in [textOnPanel, textOnSheet, textOnHover] {
            #expect(reading >= 4.5)
        }
    }

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
        #expect(isClose(textOnCanvas, 7.42, within: ratioTolerance))
        #expect(isClose(textOnHover, 4.86, within: ratioTolerance))
        for reading in [textOnPanel, textOnCanvas, textOnHover] {
            #expect(reading >= 4.5)
        }
    }

    @Test("Only the fill under white text moved, and it moved the smallest step that clears AA")
    func accentFillClearsAAUnderWhiteText() throws {
        for appearance in Appearance.allCases {
            let onAccent = try contrast(Color.white, on: DSColors.accent, in: appearance)
            #expect(isClose(onAccent, 3.65, within: ratioTolerance))
            #expect(onAccent < 4.5)

            let onFill = try contrast(Color.white, on: DSColors.accentFill, in: appearance)
            #expect(isClose(onFill, 4.65, within: ratioTolerance))
            #expect(onFill >= 4.5)

            let rejected = Color(nsColor: NSColor(srgbRed: 0.0, green: 0.46, blue: 0.94, alpha: 1.0))
            let onRejected = try contrast(Color.white, on: rejected, in: appearance)
            #expect(isClose(onRejected, 4.36, within: ratioTolerance))
            #expect(onRejected < 4.5)
        }

        for token in [DSColors.accent, DSColors.accentFill] {
            let light = try resolve(token, in: .light)
            let dark = try resolve(token, in: .dark)
            #expect(isClose(light.red, dark.red, within: componentTolerance))
            #expect(isClose(light.green, dark.green, within: componentTolerance))
            #expect(isClose(light.blue, dark.blue, within: componentTolerance))
        }
    }

    @Test("Semantic colours are readable as text on the surfaces they are drawn on")
    func semanticColoursClearAAAsText() throws {
        let amber = try resolve(DSColors.warning, in: .light)
        #expect(isClose(amber.red, 0.602, within: componentTolerance))
        #expect(isClose(amber.green, 0.373, within: componentTolerance))
        #expect(isClose(amber.blue, 0.0, within: componentTolerance))

        let amberOnPanel = try contrast(DSColors.warning, on: DSColors.secondary, in: .light)
        let greenOnPanel = try contrast(DSColors.success, on: DSColors.secondary, in: .light)
        let redOnPanel = try contrast(DSColors.destructive, on: DSColors.secondary, in: .light)
        #expect(isClose(amberOnPanel, 4.60, within: ratioTolerance))
        #expect(isClose(greenOnPanel, 4.62, within: ratioTolerance))
        #expect(isClose(redOnPanel, 4.95, within: ratioTolerance))

        let amberOnCanvas = try contrast(DSColors.warning, on: DSColors.dominant, in: .light)
        let greenOnCanvas = try contrast(DSColors.success, on: DSColors.dominant, in: .light)
        let redOnCanvas = try contrast(DSColors.destructive, on: DSColors.dominant, in: .light)
        #expect(isClose(amberOnCanvas, 5.24, within: ratioTolerance))
        #expect(isClose(greenOnCanvas, 5.26, within: ratioTolerance))
        #expect(isClose(redOnCanvas, 5.64, within: ratioTolerance))

        let white = try resolve(Color.white, in: .light)
        let greenOnSheet = try contrast(DSColors.success, on: DSColors.surfaceElevated, in: .light)
        let redOnWhite = try contrast(DSColors.destructive, on: white, in: .light)
        #expect(isClose(greenOnSheet, 4.83, within: ratioTolerance))
        #expect(isClose(redOnWhite, 5.64, within: ratioTolerance))

        for appearance in Appearance.allCases {
            for surface in [DSColors.secondary, DSColors.dominant] {
                for token in [DSColors.success, DSColors.warning, DSColors.destructive] {
                    let reading = try contrast(token, on: surface, in: appearance)
                    #expect(reading >= 4.5)
                }
            }
        }
    }

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

        #expect(isClose(greenOnPanel, 1.78, within: ratioTolerance))
        #expect(isClose(greenOnWhite, 2.02, within: ratioTolerance))
        #expect(isClose(amberOnPanel, 1.81, within: ratioTolerance))
        #expect(isClose(amberOnWhite, 2.06, within: ratioTolerance))

        for reading in [greenOnPanel, greenOnWhite, amberOnPanel, amberOnWhite] {
            #expect(reading < 2.5)
        }
    }

    // Shared app-owned backgrounds used by status pills and method badges.
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

    private func selfTintedReading(
        _ token: Color,
        on surface: RGBA,
        alpha: Double = 0.12,
        in appearance: Appearance
    ) throws -> Double {
        let fill = try resolve(token.opacity(alpha), in: appearance).composited(over: surface)
        return try contrast(token, on: fill, in: appearance)
    }

    @Test("An active state badge remains readable on the editor header in both appearances")
    func activeStateBadgeClearsAA() throws {
        #expect(DSStateBadge.fillOpacity == 0.10)
        for appearance in Appearance.allCases {
            let header = try resolve(DSColors.secondary, in: appearance)
            let reading = try selfTintedReading(
                DSColors.accentText,
                on: header,
                alpha: 0.10,
                in: appearance
            )
            #expect(reading >= 4.5, "Active badge on editor header, \(appearance): \(reading)")
        }
    }

    @Test("A status pill's text clears AA on the tint of itself the pill fills with")
    func statusPillTextClearsAAOnItsOwnFill() throws {
        var worst = Double.greatestFiniteMagnitude

        for appearance in Appearance.allCases {
            let surfaces = try pillSurfaces(in: appearance)

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
        #expect(isClose(worst, 4.55, within: ratioTolerance))

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

        for token in [DSColors.success, DSColors.warning, DSColors.destructive] {
            let reading = try contrast(token, on: panel, in: .light)
            #expect(reading >= 4.5)
        }
        let accentAsBareText = try contrast(DSColors.accent, on: panel, in: .light)
        #expect(accentAsBareText < 4.5)
    }

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

        let accentAsRedirect = try contrast(DSColors.accent, on: panel, in: .light)
        let textAsRedirect = try contrast(DSColors.httpStatusColor(for: 302), on: panel, in: .light)
        #expect(isClose(accentAsRedirect, 3.20, within: ratioTolerance))
        #expect(isClose(textAsRedirect, 5.35, within: ratioTolerance))

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
        #expect(isClose(worst, 4.57, within: ratioTolerance))

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

        let darkPanel = try resolve(DSColors.secondary, in: .dark)
        let darkSelected = try resolve(DSColors.accentSubtle, in: .dark).composited(over: darkPanel)
        let unfilledDelete = try contrast(
            Color(nsColor: NSColor(srgbRed: 1.0, green: 0.392, blue: 0.392, alpha: 1.0)),
            on: darkSelected,
            in: .dark
        )
        #expect(isClose(unfilledDelete, 4.20, within: ratioTolerance))
        #expect(unfilledDelete < 4.5)

        let put = try resolve(DSColors.methodColor(for: "PUT"), in: .dark)
        let number = try resolve(DSColors.Syntax.number, in: .dark)
        #expect(isClose(put.red, number.red, within: componentTolerance))
        #expect(isClose(put.green, number.green, within: componentTolerance))
        #expect(isClose(put.blue, number.blue, within: componentTolerance))
    }

    // Representative native material samples; full UI review covers actual system materials.
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

        let panel = try resolve(DSColors.secondary, in: .light)
        let sheetToken = try resolve(DSColors.surfaceElevated, in: .light)
        let filledOnPanel = try selfTintedReading(DSColors.warning, on: panel, in: .light)
        let filledOnToken = try selfTintedReading(DSColors.warning, on: sheetToken, in: .light)
        #expect(isClose(filledOnPanel, 3.96, within: ratioTolerance))
        #expect(isClose(filledOnToken, 4.11, within: ratioTolerance))

        let washedToken = try resolve(DSColors.accentSubtle, over: DSColors.surfaceElevated, in: .light)
        let hoveredToken = try resolve(DSColors.accentSubtle.opacity(0.6), over: DSColors.surfaceElevated, in: .light)
        let plainOnWashedToken = try contrast(DSColors.warning, on: washedToken, in: .light)
        let plainOnHoveredToken = try contrast(DSColors.warning, on: hoveredToken, in: .light)
        #expect(isClose(plainOnWashedToken, 4.17, within: ratioTolerance))
        #expect(isClose(plainOnHoveredToken, 4.43, within: ratioTolerance))
        #expect(plainOnWashedToken < 4.5)
        #expect(plainOnHoveredToken < 4.5)
    }

    @Test("A filled button keeps its white label above AA at rest, on hover and while pressed")
    func filledButtonsKeepTheirLabelAboveAAInEveryState() throws {
        let states: [(name: String, wash: Color)] = [
            ("at rest", DSButtonShade.wash(isPressed: false, isHovered: false)),
            ("hovered", DSButtonShade.wash(isPressed: false, isHovered: true)),
            ("pressed", DSButtonShade.wash(isPressed: true, isHovered: true))
        ]

        let atRest = try resolve(DSButtonShade.wash(isPressed: false, isHovered: false), in: .light)
        #expect(isClose(atRest.alpha, 0, within: componentTolerance))

        var filled = 0
        for appearance in Appearance.allCases {
            for variant in DSButtonVariant.allCases {
                guard let fill = variant.fill else { continue }
                filled += 1

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
        #expect(filled == 4)

        #expect(DSButtonVariant.allCases.filter { $0.fill == nil }.count == 2)

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

        let onTheSalmon = try contrast(Color.white, on: DSColors.destructive, in: .dark)
        #expect(isClose(onTheSalmon, 2.52, within: ratioTolerance))
        #expect(onTheSalmon < 4.5)
    }

    private var syntaxValueTokens: [(name: String, colour: Color)] {
        [
            ("key", DSColors.Syntax.key),
            ("string", DSColors.Syntax.string),
            ("number", DSColors.Syntax.number),
            ("literal", DSColors.Syntax.literal)
        ]
    }

    @Test("JSON punctuation remains readable on each body background")
    func jsonPunctuationIsReadable() throws {
        for appearance in Appearance.allCases {
            for host in [DSColors.dominant, DSColors.secondary] {
                let well = try resolve(DSColors.codeWell, over: host, in: appearance)
                let reading = try contrast(DSColors.Syntax.punctuation, on: well, in: appearance)
                #expect(reading >= 4.5, "JSON punctuation on \(host), \(appearance): \(reading)")
            }
        }
    }

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
        #expect(isClose(worst, 4.60, within: ratioTolerance))

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

        for appearance in Appearance.allCases {
            let canvas = try resolve(DSColors.dominant, in: appearance)
            for token in syntaxValueTokens {
                let reading = try contrast(token.colour, on: canvas, in: appearance)
                #expect(reading >= 4.5, "\(token.name) on the editor canvas, \(appearance): \(reading)")
            }
        }

        let literal = try resolve(DSColors.Syntax.literal, in: .dark)
        let accentText = try resolve(DSColors.accentText, in: .dark)
        #expect(isClose(literal.red, accentText.red, within: componentTolerance))
        #expect(isClose(literal.green, accentText.green, within: componentTolerance))
        #expect(isClose(literal.blue, accentText.blue, within: componentTolerance))
    }

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

        #expect(isClose(worstInk, 5.52, within: ratioTolerance))

        #expect(syntaxTokensClearingAA <= 1)
        #expect(isClose(bestSyntax, 4.59, within: ratioTolerance))

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
                #expect(tertiary < 3.5)
            }

            let tiers: [(Color, Double)] = [
                (DSColors.labelPrimary, 0.88),
                (DSColors.labelSecondary, 0.66),
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

            for rule in [border, separator, panelSeparator] {
                #expect(isClose(rule.red, appearance.ink, within: componentTolerance))
                #expect(isClose(rule.green, appearance.ink, within: componentTolerance))
                #expect(isClose(rule.blue, appearance.ink, within: componentTolerance))
            }
        }
    }

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
            try expectSameHue(DSColors.codeWell, DSColors.tertiary, alpha: 0.3, in: appearance)
            try expectSameHue(DSColors.accentSubtle, DSColors.accent, alpha: 0.12, in: appearance)
            try expectSameHue(DSColors.accentMuted, DSColors.accent, alpha: 0.25, in: appearance)
            try expectSameHue(DSColors.Syntax.searchHit, DSColors.warning, alpha: 0.35, in: appearance)

            try expectSameHue(DSColors.borderFocused, DSColors.accent, alpha: 1.0, in: appearance)
            try expectSameHue(DSColors.serverRunning, DSColors.success, alpha: 1.0, in: appearance)
            try expectSameHue(DSColors.serverError, DSColors.destructive, alpha: 1.0, in: appearance)
            try expectSameHue(
                DSColors.Syntax.punctuation,
                DSColors.labelSecondary,
                alpha: 0.66,
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

        #expect(DSColors.httpStatusColor(for: 100) == DSColors.labelSecondary)
        #expect(DSColors.httpStatusColor(for: 0) == DSColors.labelSecondary)
    }

    @Test("The running well's tint costs nothing the text on it can afford")
    func runningWellTintIsReadable() throws {
        let expected: [Appearance: (
            wellStep: Double,
            address: Double,
            unmatched: Double,
            countGlyph: Double,
            chipAtRest: Double,
            chipHovered: Double,
            chipConfirming: Double,
            inkWashAtRest: Double,
            inkWashHovered: Double
        )] = [
            .light: (6.09, 12.94, 5.31, 6.46, 6.70, 4.98, 5.76, 6.12, 4.03),
            .dark: (7.08, 9.01, 5.40, 5.86, 5.98, 4.54, 5.61, 5.18, 3.96)
        ]

        for appearance in Appearance.allCases {
            let bar = try #require(expected[appearance])
            let toolbar = try resolve(DSColors.secondary, in: appearance)
            let well = try resolve(DSColors.successSubtle, in: appearance).composited(over: toolbar)
            let chip = try resolve(DSColors.tertiary, in: appearance).composited(over: well)

            let step = deltaLStar(well, toolbar)
            #expect(
                isClose(step, bar.wellStep, within: deltaLTolerance),
                "The tint's step off the toolbar is \(step) in \(appearance), documented as \(bar.wellStep)"
            )

            let address = try contrast(DSColors.labelPrimary, on: well, in: appearance)
            let unmatched = try contrast(DSColors.httpStatusColor(for: 404), on: well, in: appearance)
            #expect(isClose(address, bar.address, within: ratioTolerance))
            #expect(isClose(unmatched, bar.unmatched, within: ratioTolerance))
            #expect(address >= 4.5, "The address reads \(address) in \(appearance)")
            #expect(unmatched >= 4.5, "The unmatched badge reads \(unmatched) in \(appearance)")

            let countGlyph = try contrast(DSColors.labelSecondary, on: well, in: appearance)
            #expect(isClose(countGlyph, bar.countGlyph, within: ratioTolerance))
            #expect(countGlyph >= 4.5, "The count glyph reads \(countGlyph) in \(appearance)")

            let atRest = try contrast(DSColors.labelSecondary, on: chip, in: appearance)
            let hovered = try contrast(DSColors.accentText, on: chip, in: appearance)
            let confirming = try contrast(DSColors.successText, on: chip, in: appearance)
            #expect(isClose(atRest, bar.chipAtRest, within: ratioTolerance))
            #expect(isClose(hovered, bar.chipHovered, within: ratioTolerance))
            #expect(isClose(confirming, bar.chipConfirming, within: ratioTolerance))
            for (state, reading) in [("at rest", atRest), ("hovered", hovered), ("confirming", confirming)] {
                #expect(reading >= 4.5, "The copy chip \(state) reads \(reading) in \(appearance)")
            }

            let inkWash = try resolve(DSColors.labelPrimary.opacity(0.06), in: appearance)
                .composited(over: well)
            let inkWashHover = try resolve(DSColors.accentSubtle, in: appearance)
                .composited(over: well)
            let wasAtRest = try contrast(DSColors.labelSecondary, on: inkWash, in: appearance)
            let wasHovered = try contrast(DSColors.accentText, on: inkWashHover, in: appearance)
            #expect(isClose(wasAtRest, bar.inkWashAtRest, within: ratioTolerance))
            #expect(isClose(wasHovered, bar.inkWashHovered, within: ratioTolerance))
            #expect(wasAtRest >= 4.5, "The 6% ink wash should now be readable at rest")
            #expect(wasHovered < 4.5, "An `accentSubtle` hover on it failed in both appearances")
        }
    }
}
