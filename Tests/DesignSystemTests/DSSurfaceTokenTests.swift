import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// The surface migration, pinned where it claims to be free.
///
/// The rename of `tertiary` → `surfaceWell` was sold as a **zero-pixel change**, and that claim is
/// only worth anything if something checks it. These read the resolved sRGB value back out of each
/// token in both appearances — which is also the only way to catch a `Color` whose light and dark
/// arms were transposed, since nothing else in the type system distinguishes them.
@Suite("Surface tokens")
@MainActor
struct DSSurfaceTokenTests {

    private func hex(_ color: Color, dark: Bool) -> String {
        var result = ""
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            result = String(
                format: "#%02X%02X%02X",
                Int((resolved.redComponent * 255).rounded()),
                Int((resolved.greenComponent * 255).rounded()),
                Int((resolved.blueComponent * 255).rounded())
            )
        }
        return result
    }

    @Test("The renamed tokens are byte-identical to what they replaced — the migration drew nothing new")
    func renamesAreValueIdentical() {
        #expect(hex(DSColors.surfaceWell, dark: false) == hex(DSColors.tertiary, dark: false))
        #expect(hex(DSColors.surfaceWell, dark: true) == hex(DSColors.tertiary, dark: true))
        #expect(hex(DSColors.surfacePanelHeader, dark: false) == hex(DSColors.secondary, dark: false))
        #expect(hex(DSColors.surfacePanelHeader, dark: true) == hex(DSColors.secondary, dark: true))
    }

    @Test("Every surface matches the value the design specifies")
    func surfacesMatchTheSpecifiedHexes() {
        #expect(hex(DSColors.surfaceContent, dark: false) == "#FCFCFD")
        #expect(hex(DSColors.surfaceContent, dark: true) == "#1A1A1C")
        #expect(hex(DSColors.surfaceSidebar, dark: false) == "#F1F1F3")
        #expect(hex(DSColors.surfaceSidebar, dark: true) == "#232325")
        #expect(hex(DSColors.surfacePanelHeader, dark: false) == "#F0F0F2")
        #expect(hex(DSColors.surfacePanelHeader, dark: true) == "#2C2C2E")
        #expect(hex(DSColors.surfaceWell, dark: false) == "#E8E8EC")
        #expect(hex(DSColors.surfaceWell, dark: true) == "#3A3A3C")
        #expect(hex(DSColors.surfaceElevated, dark: false) == "#FFFFFF")
        #expect(hex(DSColors.surfaceElevated, dark: true) == "#2C2C2E")
    }

    @Test("A panel header on the sidebar surface would be invisible — which is why it takes no fill")
    func panelHeaderOnSidebarIsBelowTheVisibilityFloor() {
        // The measurement that changed the plan. ΔL* between the two, computed the way the rest of
        // this palette's notes compute it. If someone ever "simplifies" the header back onto a fill
        // over the sidebar, this is the number that says why not.
        func luminance(_ hexString: String) -> Double {
            let v = Int(hexString.dropFirst(), radix: 16)!
            let parts = [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF].map { Double($0) / 255.0 }
            let linear = parts.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        func lStar(_ hexString: String) -> Double {
            let y = luminance(hexString)
            return y <= 0.008856 ? y * 903.3 : 116 * pow(y, 1.0 / 3.0) - 16
        }

        let delta = abs(lStar(hex(DSColors.surfacePanelHeader, dark: false))
                        - lStar(hex(DSColors.surfaceSidebar, dark: false)))
        #expect(delta < 1.0, "measured ΔL* \(delta) — far below the 1.4 floor this palette allows a band")
    }

    @Test("In dark, elevated and the panel header share a value on purpose")
    func darkElevationIsCarriedByShadowNotFill() {
        // Not a copy-paste slip. A near-black surface has nowhere brighter to go that does not read
        // as grey plastic, so a dark-mode card is separated by its shadow and its 0.5pt border.
        #expect(hex(DSColors.surfaceElevated, dark: true) == hex(DSColors.surfacePanelHeader, dark: true))
        // In light they must differ, or a card has no lift at all.
        #expect(hex(DSColors.surfaceElevated, dark: false) != hex(DSColors.surfacePanelHeader, dark: false))
    }
}
