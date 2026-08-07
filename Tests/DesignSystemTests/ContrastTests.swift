import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// Every text-on-surface pairing in the window, measured rather than eyeballed.
///
/// The palette holds itself to **4.5:1**, and the reason it needs a harness rather than a
/// convention is that most of the failures are not on plain surfaces — they are text on a *tinted
/// fill* over a surface, where the effective background is a composite nobody can read off a swatch.
/// `warning` on `warning @ 13%` looks obviously fine and measures 3.9:1.
///
/// Three rules this encodes, all learned the expensive way:
///
/// 1. **Composite in 8-bit sRGB, the way CoreGraphics does.** Compositing in float and rounding at
///    the end gives answers that differ in the second decimal, which is exactly the margin several
///    of these pairings live in.
/// 2. **Measure against the surface actually behind the text**, not against white. A 16% fill over
///    `surfaceContent` and the same fill over a striped row are different backgrounds.
/// 3. **Both appearances, every time.** Four of the failures found while building this were in the
///    appearance nobody expected, and two were in dark mode on `surfaceElevated`.
@Suite("Contrast")
@MainActor
struct ContrastTests {

    // MARK: - Measurement

    private struct RGB {
        var r: Double, g: Double, b: Double

        /// 8-bit sRGB compositing — `self` at `alpha` over `background`, rounded per channel the way
        /// the compositor does before anything reads the result back.
        func composited(over background: RGB, alpha: Double) -> RGB {
            func blend(_ top: Double, _ bottom: Double) -> Double {
                (Double(Int((top * alpha + bottom * (1 - alpha)) * 255 + 0.5))) / 255
            }
            return RGB(r: blend(r, background.r), g: blend(g, background.g), b: blend(b, background.b))
        }

        var relativeLuminance: Double {
            func linear(_ c: Double) -> Double {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
    }

    private func rgb(_ color: Color, dark: Bool) -> RGB {
        var out = RGB(r: 0, g: 0, b: 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            out = RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }
        return out
    }

    /// The alpha a token carries, which `NSColor` reports separately from its channels.
    private func alpha(_ color: Color, dark: Bool) -> Double {
        var out = 1.0
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB)!.alphaComponent
        }
        return out
    }

    /// Contrast of `foreground` — composited over `background` if it is translucent — against that
    /// same background.
    private func ratio(_ foreground: Color, on background: Color, dark: Bool) -> Double {
        let bg = rgb(background, dark: dark)
        let fgAlpha = alpha(foreground, dark: dark)
        let fg = fgAlpha < 1
            ? rgb(foreground, dark: dark).composited(over: bg, alpha: fgAlpha)
            : rgb(foreground, dark: dark)
        return contrast(fg, bg)
    }

    /// Contrast of `foreground` against `fill` at `fillAlpha` over `surface` — the tinted-fill case
    /// that most of this palette's near-misses live in.
    private func ratio(
        _ foreground: Color,
        onFill fill: Color,
        alpha fillAlpha: Double,
        over surface: Color,
        dark: Bool
    ) -> Double {
        let composited = rgb(fill, dark: dark)
            .composited(over: rgb(surface, dark: dark), alpha: fillAlpha)
        let fgAlpha = alpha(foreground, dark: dark)
        let fg = fgAlpha < 1
            ? rgb(foreground, dark: dark).composited(over: composited, alpha: fgAlpha)
            : rgb(foreground, dark: dark)
        return contrast(fg, composited)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let l1 = a.relativeLuminance, l2 = b.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private let floor = 4.5

    // MARK: - Text on the four surfaces

    @Test("Every label tier that carries meaning clears 4.5:1 on every surface")
    func labelsClearTheFloorOnEverySurface() {
        let surfaces: [(String, Color)] = [
            ("content", DSColors.surfaceContent),
            ("sidebar", DSColors.surfaceSidebar),
            ("panelHeader", DSColors.surfacePanelHeader),
            ("well", DSColors.surfaceWell),
            ("elevated", DSColors.surfaceElevated),
        ]
        for dark in [false, true] {
            for (name, surface) in surfaces {
                for (tier, color) in [("primary", DSColors.labelPrimary), ("secondary", DSColors.labelSecondary)] {
                    let r = ratio(color, on: surface, dark: dark)
                    #expect(r >= floor, "label\(tier) on \(name) \(dark ? "dark" : "light"): \(String(format: "%.2f", r)):1")
                }
            }
        }
        // `labelTertiary` is deliberately excluded. It is 36% alpha, it measures ~2.5:1, and the rule
        // is that nothing a user must read sits there — timestamps and hints only. A test that
        // asserted it passes would be asserting the wrong thing.
    }

    @Test("Semantic colours read as text on every row surface, including a striped one")
    func semanticsClearTheFloorAsText() {
        let semantics: [(String, Color)] = [
            ("success", DSColors.success),
            ("warning", DSColors.warning),
            ("destructive", DSColors.destructive),
        ]
        for dark in [false, true] {
            for (name, color) in semantics {
                // Plain content row.
                let plain = ratio(color, on: DSColors.surfaceContent, dark: dark)
                #expect(plain >= floor, "\(name) on content \(dark ? "dark" : "light"): \(String(format: "%.2f", plain)):1")

                // Striped row — the stripe composites over the content surface.
                let striped = ratio(
                    color,
                    onFill: dark ? .white : .black,
                    alpha: dark ? 0.025 : 0.016,
                    over: DSColors.surfaceContent,
                    dark: dark
                )
                #expect(striped >= floor, "\(name) on stripe \(dark ? "dark" : "light"): \(String(format: "%.2f", striped)):1")
            }
        }
    }

    @Test("The accent as a word clears the floor wherever it is a word")
    func accentTextClearsTheFloor() {
        for dark in [false, true] {
            for (name, surface) in [("content", DSColors.surfaceContent),
                                    ("sidebar", DSColors.surfaceSidebar),
                                    ("elevated", DSColors.surfaceElevated)] {
                let r = ratio(DSColors.accentText, on: surface, dark: dark)
                #expect(r >= floor, "accentText on \(name) \(dark ? "dark" : "light"): \(String(format: "%.2f", r)):1")
            }
            // On its own hover wash — the case that made `accentText` exist, since `accent` itself
            // measured 2.80:1 there and the reading got *worse* the moment you pointed at it.
            let onHover = ratio(
                DSColors.accentText,
                onFill: DSColors.accent, alpha: 0.12,
                over: DSColors.surfaceContent, dark: dark
            )
            #expect(onHover >= floor, "accentText on accentSubtle \(dark ? "dark" : "light"): \(String(format: "%.2f", onHover)):1")
        }
    }

    @Test("White on the accent fill — the commit button in every sheet")
    func whiteOnAccentFillClearsTheFloor() {
        for dark in [false, true] {
            let r = ratio(.white, on: DSColors.accentFill, dark: dark)
            #expect(r >= floor, "white on accentFill \(dark ? "dark" : "light"): \(String(format: "%.2f", r)):1")
        }
    }

    @Test("Syntax colours read on the well they are drawn in, not on the window")
    func syntaxClearsTheFloorOnTheWell() {
        let syntax: [(String, Color)] = [
            ("key", DSColors.Syntax.key),
            ("string", DSColors.Syntax.string),
            ("number", DSColors.Syntax.number),
            ("literal", DSColors.Syntax.literal),
        ]
        for dark in [false, true] {
            for (name, color) in syntax {
                let r = ratio(color, on: DSColors.surfaceWell, dark: dark)
                #expect(r >= floor, "syntax.\(name) on well \(dark ? "dark" : "light"): \(String(format: "%.2f", r)):1")
            }
        }
    }

    @Test("Every method badge reads on its own tinted fill, on every surface it lands on")
    func methodBadgesClearTheFloorOnTheirFill() {
        let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
        let surfaces: [(String, Color)] = [
            ("content", DSColors.surfaceContent),
            ("sidebar", DSColors.surfaceSidebar),
            ("elevated", DSColors.surfaceElevated),
        ]
        for dark in [false, true] {
            for method in methods {
                let hue = DSColors.methodColor(for: method)
                for (surfaceName, surface) in surfaces {
                    let r = ratio(hue, onFill: hue, alpha: 0.13, over: surface, dark: dark)
                    #expect(
                        r >= floor,
                        "\(method) on its 13% fill over \(surfaceName) \(dark ? "dark" : "light"): \(String(format: "%.2f", r)):1"
                    )
                }
            }
        }
    }
}
