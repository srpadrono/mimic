import CoreGraphics
import Testing
@testable import AppFeatures

@Suite("First-endpoint chooser layout")
@MainActor
struct CenterPaneLayoutTests {

    @Test("Three cards share a row until they would be narrower than 168pt, then two, then one")
    func cardsWrapOnlyWhenTooNarrow() {
        // 3 × 168 + 2 × 16 = 536; 2 × 168 + 16 = 352.
        #expect(CenterPaneView.chooserColumns(forWidth: 692) == 3)
        #expect(CenterPaneView.chooserColumns(forWidth: 536) == 3)
        #expect(CenterPaneView.chooserColumns(forWidth: 535) == 2)
        #expect(CenterPaneView.chooserColumns(forWidth: 352) == 2)
        #expect(CenterPaneView.chooserColumns(forWidth: 351) == 1)
        #expect(CenterPaneView.chooserColumns(forWidth: 0) == 1)
        #expect(CenterPaneView.chooserColumns(forWidth: 5_000) == 3)
    }
}
