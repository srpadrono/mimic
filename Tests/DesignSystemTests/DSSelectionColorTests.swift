import AppKit
import Testing
@testable import DesignSystem

/// `DSColors.selection` is the boards' exact `--sel` only while the accent is the default blue, and
/// the system's selected-content colour otherwise. The accent is passed in, so these hold whatever
/// accent the test machine has.
@Suite("DSColors.selection")
struct DSSelectionColorTests {
    private func srgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private func hex(of color: NSColor) throws -> UInt32 {
        let converted = try #require(color.usingColorSpace(.sRGB))
        let red = UInt32((converted.redComponent * 255).rounded())
        let green = UInt32((converted.greenComponent * 255).rounded())
        let blue = UInt32((converted.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }

    @Test("The system blues and Mimic's own accent count as the default blue",
          arguments: [0x007AFF, 0x0A84FF] as [UInt32])
    func defaultBluesAreRecognised(accent: UInt32) {
        #expect(DSColors.isDefaultBlue(srgb(accent)))
    }

    /// The other system accents, light values: purple, pink, red, orange, yellow, green, graphite.
    @Test("Every other accent is not the default blue",
          arguments: [0xAF52DE, 0xFF2D55, 0xFF3B30, 0xFF9500, 0xFFCC00, 0x28CD41, 0x8C8C8C] as [UInt32])
    func otherAccentsAreNotDefaultBlue(accent: UInt32) {
        #expect(!DSColors.isDefaultBlue(srgb(accent)))
    }

    @Test("With the default blue the fill is the boards' --sel in each appearance")
    func defaultBlueUsesTheBoardsSelection() throws {
        let light = DSColors.selectionColor(accent: srgb(0x007AFF), isDark: false, isHighContrast: false)
        let dark = DSColors.selectionColor(accent: srgb(0x0A84FF), isDark: true, isHighContrast: false)
        #expect(try hex(of: light) == 0x0A74F0)
        #expect(try hex(of: dark) == 0x0A6CE0)
    }

    @Test("Another accent, or Increase Contrast, falls back to the system's selected-content colour")
    func otherAccentsUseTheSystemSelection() {
        let purple = DSColors.selectionColor(accent: srgb(0xAF52DE), isDark: false, isHighContrast: false)
        #expect(purple == NSColor.selectedContentBackgroundColor)
        let highContrast = DSColors.selectionColor(accent: srgb(0x007AFF), isDark: false, isHighContrast: true)
        #expect(highContrast == NSColor.selectedContentBackgroundColor)
    }
}
