import CoreGraphics
import Testing
@testable import FeatureSupport

/// The sheets' height on a pinned UI test launch: CI's 674pt visible frame on a larger Mac, and the
/// real screen whenever nothing is pinned or the screen is smaller than the pin.
@Suite("Screen metrics")
struct ScreenMetricsTests {
    @Test("Nothing pinned reads the real screen")
    func unpinned() {
        #expect(ScreenMetrics.visibleHeight(real: 1055, pinned: nil) == 1055)
    }

    @Test("A pin shorter than the screen is the height a sheet sees")
    func pinnedOnALargerScreen() {
        #expect(ScreenMetrics.visibleHeight(real: 1055, pinned: 674) == 674)
    }

    @Test("A pin taller than the screen never makes it taller")
    func pinnedOnASmallerScreen() {
        #expect(ScreenMetrics.visibleHeight(real: 600, pinned: 674) == 600)
    }
}
