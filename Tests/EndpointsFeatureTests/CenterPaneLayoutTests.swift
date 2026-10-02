import CoreGraphics
import Testing
@testable import EndpointsFeature

@Suite("First-endpoint chooser layout")
@MainActor
struct CenterPaneLayoutTests {

    @Test("Three cards share a row until they would be narrower than 204pt, then two, then one")
    func cardsWrapOnlyWhenTooNarrow() {
        // A 204pt card is a 168pt text column in 18pt of padding.
        // 3 × 204 + 2 × 16 = 644; 2 × 204 + 16 = 424.
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 800) == 3)
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 644) == 3)
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 643) == 2)
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 424) == 2)
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 423) == 1)
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 0) == 1)
        #expect(FirstEndpointChooser.chooserColumns(forWidth: 5_000) == 3)
    }

    @Test("Cards fill rows in order, the last row holding what is left")
    func cardsSplitIntoRows() {
        #expect(FirstEndpointChooser.rows(of: [1, 2, 3], columns: 3) == [[1, 2, 3]])
        #expect(FirstEndpointChooser.rows(of: [1, 2, 3], columns: 2) == [[1, 2], [3]])
        #expect(FirstEndpointChooser.rows(of: [1, 2, 3], columns: 1) == [[1], [2], [3]])
    }
}
