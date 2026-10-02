import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// The two appearances every colour role resolves in.
///
/// `nonisolated` because this target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and
/// a `CaseIterable` conformance whose `allCases` lands on the main actor is a witness the protocol
/// never asked for.
private nonisolated enum Appearance: String, CaseIterable, CustomStringConvertible {
    case light
    case dark

    var description: String { rawValue }
}

/// A resolved sRGB colour and the WCAG arithmetic every reading below is stated in.
private nonisolated struct RGBA {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// An opaque colour from a hex literal, for expected values written independently of `DSColors`.
    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        alpha = 1
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The colour as a screen holds it: eight bits per channel.
    var rendered: RGBA {
        RGBA(
            red: (red * 255).rounded() / 255,
            green: (green * 255).rounded() / 255,
            blue: (blue * 255).rounded() / 255,
            alpha: alpha
        )
    }

    /// WCAG 2.1 relative luminance with the sRGB transfer function.
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

/// Text roles measured against the surfaces they sit on, after every translucent ink and fill is
/// composited.
///
/// The thresholds are WCAG 2.1: 4.5:1 for text a person reads (`labelPrimary`, `labelSecondary`, the
/// status and method colours, all 11pt–13pt), and 3:1 for `labelTertiary`, which the palette keeps
/// for placeholders, units and decoration. Every role clears its threshold in both appearances.
///
/// Only the standard light and dark appearances are resolved. The Increase Contrast variants raise
/// the alpha of the label and separator roles, so they can only improve on these readings.
@Suite("DesignSystem colour contrast")
@MainActor
struct DSContrastTests {
    /// Ratios are quoted to a hundredth; the eight-bit read-back can move the last digit.
    private let ratioTolerance = 0.05

    /// One eight-bit step is 0.0039, so this checks the right code value was reached.
    private let componentTolerance = 0.001

    private func isClose(_ measured: Double, _ expected: Double, within tolerance: Double) -> Bool {
        abs(measured - expected) < tolerance
    }

    // MARK: - Resolution

    /// Resolves a colour under one appearance. The conversion sits inside
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
        let srgb = try #require(resolved, "every DSColors role must convert to sRGB")
        return RGBA(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }

    /// The ratio a reader gets: the ink is flattened onto its bed before it is measured.
    private func contrast(_ foreground: Color, on background: RGBA, in appearance: Appearance) throws -> Double {
        let ink = try resolve(foreground, in: appearance).composited(over: background)
        return contrastRatio(ink, background)
    }

    /// The five surfaces text is drawn on.
    private func surfaces(in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        [
            ("content", try resolve(DSColors.content, in: appearance)),
            ("window", try resolve(DSColors.window, in: appearance)),
            ("sheet", try resolve(DSColors.sheet, in: appearance)),
            ("code", try resolve(DSColors.code, in: appearance)),
            ("raised", try resolve(DSColors.raised, in: appearance)),
        ]
    }

    /// The surfaces, plus an alternate table row: the request log and the import review stripe
    /// their rows with `zebra` over the content surface.
    private func beds(in appearance: Appearance) throws -> [(name: String, colour: RGBA)] {
        let content = try resolve(DSColors.content, in: appearance)
        let zebra = try resolve(DSColors.zebra, in: appearance).composited(over: content)
        return try surfaces(in: appearance) + [("zebra row", zebra)]
    }

    private func expectSame(_ measured: RGBA, _ expected: RGBA, _ label: String) {
        #expect(isClose(measured.rendered.red, expected.red, within: componentTolerance), "\(label) red")
        #expect(isClose(measured.rendered.green, expected.green, within: componentTolerance), "\(label) green")
        #expect(isClose(measured.rendered.blue, expected.blue, within: componentTolerance), "\(label) blue")
    }

    // MARK: - Surfaces

    /// Every reading below rests on the surfaces resolving per appearance. Pinned against hex
    /// literals, so a resolver that silently measured light twice fails here first.
    @Test("Surfaces resolve to the palette's values in each appearance")
    func surfacesResolvePerAppearance() throws {
        let expected: [Appearance: [String: UInt32]] = [
            .light: ["content": 0xFFFFFF, "window": 0xF6F6F7, "sheet": 0xF7F7F8, "code": 0xFBFBFC, "raised": 0xFFFFFF],
            .dark: ["content": 0x1B1B1D, "window": 0x1E1E20, "sheet": 0x2A2A2D, "code": 0x161618, "raised": 0x2C2C2F],
        ]
        for appearance in Appearance.allCases {
            for surface in try surfaces(in: appearance) {
                let hex = try #require(expected[appearance]?[surface.name])
                #expect(surface.colour.alpha == 1, "\(surface.name) is opaque in \(appearance)")
                expectSame(surface.colour, RGBA(hex: hex), "\(surface.name), \(appearance)")
            }
        }
    }

    /// The sheet boards draw fields white in light and a step above the sheet in dark, and lift a
    /// settings group a smaller step off the sheet. Flattened onto the sheet, as they are drawn.
    @Test("Sheet fields and settings groups match the sheet boards")
    func sheetControlsMatchTheBoards() throws {
        let expected: [Appearance: [String: UInt32]] = [
            .light: ["field": 0xFFFFFF, "group": 0xFFFFFF],
            .dark: ["field": 0x38383B, "group": 0x343436],
        ]
        for appearance in Appearance.allCases {
            let sheet = try resolve(DSColors.sheet, in: appearance)
            let readings: [(name: String, colour: Color)] = [
                ("field", DSSurface.sheet.fieldFill),
                ("group", DSColors.formGroup),
            ]
            for reading in readings {
                let hex = try #require(expected[appearance]?[reading.name])
                let flattened = try resolve(reading.colour, in: appearance).composited(over: sheet)
                expectSame(flattened, RGBA(hex: hex), "\(reading.name) on a sheet, \(appearance)")
            }
        }
    }

    /// Outside a sheet a field keeps the window's quiet wash, so only sheets change.
    @Test("Window fields keep the window wash")
    func windowFieldsKeepTheWash() throws {
        let light = try resolve(DSSurface.window.fieldFill, in: .light)
        #expect(isClose(light.alpha, 0.045, within: componentTolerance))
        #expect(light.red == 0)
    }

    // MARK: - Labels

    /// The three label roles on the five surfaces, as measured. A change to any ink or surface moves
    /// one of these numbers, which is the point: the change is then deliberate.
    @Test("Label ratios on every surface are the measured values")
    func labelRatiosAreMeasured() throws {
        // surface: (primary, secondary, tertiary)
        let expected: [Appearance: [String: (Double, Double, Double)]] = [
            .light: [
                "content": (16.48, 4.72, 3.26),
                "window": (15.44, 4.56, 3.18),
                "sheet": (15.57, 4.60, 3.17),
                "code": (16.12, 4.69, 3.24),
                "raised": (16.48, 4.72, 3.26),
            ],
            .dark: [
                "content": (14.69, 6.30, 3.20),
                "window": (14.22, 6.18, 3.19),
                "sheet": (12.33, 5.64, 3.04),
                "code": (15.31, 6.46, 3.21),
                "raised": (12.00, 5.49, 3.04),
            ],
        ]
        for appearance in Appearance.allCases {
            for surface in try surfaces(in: appearance) {
                let reading = try #require(expected[appearance]?[surface.name])
                let primary = try contrast(DSColors.labelPrimary, on: surface.colour, in: appearance)
                let secondary = try contrast(DSColors.labelSecondary, on: surface.colour, in: appearance)
                let tertiary = try contrast(DSColors.labelTertiary, on: surface.colour, in: appearance)
                let place = "on \(surface.name), \(appearance)"
                #expect(isClose(primary, reading.0, within: ratioTolerance), "labelPrimary \(place): \(primary)")
                #expect(isClose(secondary, reading.1, within: ratioTolerance), "labelSecondary \(place): \(secondary)")
                #expect(isClose(tertiary, reading.2, within: ratioTolerance), "labelTertiary \(place): \(tertiary)")
            }
        }
    }

    @Test("Primary and secondary labels clear AA on every surface")
    func primaryAndSecondaryLabelsClearAA() throws {
        for appearance in Appearance.allCases {
            for surface in try surfaces(in: appearance) {
                let primary = try contrast(DSColors.labelPrimary, on: surface.colour, in: appearance)
                let secondary = try contrast(DSColors.labelSecondary, on: surface.colour, in: appearance)
                // Primary text clears AAA with room to spare; secondary text clears AA.
                #expect(primary >= 7, "labelPrimary on \(surface.name), \(appearance): \(primary)")
                #expect(secondary >= 4.5, "labelSecondary on \(surface.name), \(appearance): \(secondary)")
            }
        }
    }

    @Test("The three labels stay a ladder on every surface")
    func labelsStayALadder() throws {
        for appearance in Appearance.allCases {
            for surface in try surfaces(in: appearance) {
                let primary = try contrast(DSColors.labelPrimary, on: surface.colour, in: appearance)
                let secondary = try contrast(DSColors.labelSecondary, on: surface.colour, in: appearance)
                let tertiary = try contrast(DSColors.labelTertiary, on: surface.colour, in: appearance)
                #expect(primary > secondary, "\(surface.name), \(appearance)")
                #expect(secondary > tertiary, "\(surface.name), \(appearance)")
            }
        }
    }

    /// Placeholders, units and section headers are allowed 3:1, in both appearances.
    @Test("Tertiary labels clear 3:1 on every surface")
    func tertiaryLabelsClearThreeToOne() throws {
        for appearance in Appearance.allCases {
            for surface in try surfaces(in: appearance) {
                let tertiary = try contrast(DSColors.labelTertiary, on: surface.colour, in: appearance)
                #expect(tertiary >= 3, "labelTertiary on \(surface.name), \(appearance): \(tertiary)")
            }
        }
    }

    // MARK: - Status

    /// On the content surface, where the request log draws them.
    @Test("Status colours on the content surface are the measured values")
    func statusRatiosOnContentAreMeasured() throws {
        let expected: [Appearance: [(Int, Double)]] = [
            .light: [(200, 5.43), (302, 5.78), (404, 5.64), (500, 5.22)],
            .dark: [(200, 8.50), (302, 7.00), (404, 9.64), (500, 5.75)],
        ]
        for appearance in Appearance.allCases {
            let content = try resolve(DSColors.content, in: appearance)
            let readings = try #require(expected[appearance])
            for (code, reading) in readings {
                let ratio = try contrast(DSColors.httpStatusColor(for: code), on: content, in: appearance)
                #expect(isClose(ratio, reading, within: ratioTolerance), "\(code), \(appearance): \(ratio)")
            }
        }
    }

    /// Status codes and state words are 12pt text, so they are held to 4.5:1 on every surface and on
    /// a striped row.
    @Test("Status colours clear AA as text on every surface and striped row")
    func statusColoursClearAA() throws {
        let roles: [(String, Color)] = [
            ("success", DSColors.success),
            ("redirect", DSColors.redirect),
            ("warning", DSColors.warning),
            ("error", DSColors.error),
        ]
        for appearance in Appearance.allCases {
            for bed in try beds(in: appearance) {
                for (name, role) in roles {
                    let ratio = try contrast(role, on: bed.colour, in: appearance)
                    #expect(ratio >= 4.5, "\(name) on \(bed.name), \(appearance): \(ratio)")
                }
            }
        }
    }

    // MARK: - Methods

    @Test("Method colours are the palette's values, and unknown methods share one grey")
    func methodColoursAreThePalettesValues() throws {
        let expected: [(String, UInt32, UInt32)] = [
            ("GET", 0x0A62CC, 0x5AA9FF),
            ("post", 0x18823A, 0x4FD07B),
            ("PUT", 0xA85A00, 0xFFA94D),
            ("Patch", 0x8433C4, 0xC79BFF),
            ("DELETE", 0xC42B27, 0xFF6B66),
            ("HEAD", 0x62626A, 0xA1A1AA),
            ("OPTIONS", 0x62626A, 0xA1A1AA),
            ("TRACE", 0x62626A, 0xA1A1AA),
        ]
        for (method, light, dark) in expected {
            expectSame(try resolve(DSColors.methodColor(for: method), in: .light), RGBA(hex: light), "\(method), light")
            expectSame(try resolve(DSColors.methodColor(for: method), in: .dark), RGBA(hex: dark), "\(method), dark")
        }
    }

    /// Method labels sit in the sidebar, the request log, the import review and sheets, at SF Mono
    /// 11 semibold, so each clears 4.5:1 on every surface and on a striped row.
    @Test("Method colours clear AA on every surface and striped row")
    func methodColoursClearAA() throws {
        for appearance in Appearance.allCases {
            for bed in try beds(in: appearance) {
                for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] {
                    let ratio = try contrast(DSColors.methodColor(for: method), on: bed.colour, in: appearance)
                    #expect(ratio >= 4.5, "\(method) on \(bed.name), \(appearance): \(ratio)")
                }
            }
        }
    }

    // MARK: - Code

    @Test("Syntax colours and punctuation clear AA in the code well")
    func syntaxColoursClearAAInTheCodeWell() throws {
        let roles: [(String, Color)] = [
            ("key", DSColors.Syntax.key),
            ("string", DSColors.Syntax.string),
            ("number", DSColors.Syntax.number),
            ("literal", DSColors.Syntax.literal),
            ("punctuation", DSColors.Syntax.punctuation),
        ]
        for appearance in Appearance.allCases {
            let well = try resolve(DSColors.code, in: appearance)
            for (name, role) in roles {
                let ratio = try contrast(role, on: well, in: appearance)
                #expect(ratio >= 4.5, "\(name) in the code well, \(appearance): \(ratio)")
            }
        }
    }

    // MARK: - Banners

    /// A banner's message is `labelPrimary` on its tinted fill, and its glyph is the tone's ink. The
    /// message is text (4.5:1); the glyph is a graphic beside words that already say the same thing,
    /// so it is held to the 3:1 for non-text contrast.
    @Test("Banner messages clear AA and banner glyphs clear 3:1 on every fill")
    func bannersAreReadable() throws {
        let tones: [(String, Color, Color)] = [
            ("warning", DSColors.warningBackground, DSColors.warning),
            ("error", DSColors.errorBackground, DSColors.error),
        ]
        for appearance in Appearance.allCases {
            for surface in try surfaces(in: appearance) {
                for (name, fill, ink) in tones {
                    let bed = try resolve(fill, in: appearance).composited(over: surface.colour)
                    let message = try contrast(DSColors.labelPrimary, on: bed, in: appearance)
                    let glyph = try contrast(ink, on: bed, in: appearance)
                    let key = "\(name) banner on \(surface.name), \(appearance)"
                    #expect(message >= 4.5, "\(key) message: \(message)")
                    #expect(glyph >= 3, "\(key) glyph: \(glyph)")
                }
            }
        }
    }
}
