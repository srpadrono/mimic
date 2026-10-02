import CoreGraphics
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("DSDisclosureChevron")
struct DSDisclosureChevronTests {
    /// The boards' `.ic` stroke is 1.5 units of a 16-unit box; their chevrons draw that box at 10pt.
    @Test("The stroke is the boards' 1.5 units, 0.9375pt in the 10pt square")
    func strokeScalesWithTheSquare() {
        #expect(DSDisclosureChevron.strokeWidth(for: 10) == 0.9375)
        #expect(DSDisclosureChevron.strokeWidth(for: 16) == 1.5)
    }

    /// The paths are the boards' own: `M6 3l5 5-5 5`, `M4 6l4 4 4-4` and `M5 6l3-3 3 3M5 10l3 3 3-3`.
    @Test("Each direction draws the boards' path in its 16-unit square")
    func pathsMatchTheBoards() {
        let square = CGRect(x: 0, y: 0, width: 16, height: 16)
        let right = DSDisclosureChevronShape(direction: .right).path(in: square).boundingRect
        #expect(right == CGRect(x: 6, y: 3, width: 5, height: 10))
        let down = DSDisclosureChevronShape(direction: .down).path(in: square).boundingRect
        #expect(down == CGRect(x: 4, y: 6, width: 8, height: 4))
        let upDown = DSDisclosureChevronShape(direction: .upDown).path(in: square).boundingRect
        #expect(upDown == CGRect(x: 5, y: 3, width: 6, height: 10))
    }

    /// In the 10pt square the jump bar draws, the right chevron is 3.125pt wide and 6.25pt tall.
    @Test("The 10pt square scales the path by ten sixteenths")
    func pathScalesIntoTheTenPointSquare() {
        let box = DSDisclosureChevronShape(direction: .right)
            .path(in: CGRect(x: 0, y: 0, width: 10, height: 10)).boundingRect
        #expect(box == CGRect(x: 3.75, y: 1.875, width: 3.125, height: 6.25))
    }
}
