import Foundation
import Testing
@testable import AppFeatures

/// The request log's column widths.
///
/// The header cells and the row cells read the same constants — that is what keeps a column heading
/// over its own column — so the value being in one place is the property worth protecting, and these
/// cases protect the *reasoning* attached to each number rather than restating the number itself.
///
/// The table draws Time, Method, Path, Status, then Scenario, Duration and Size, which it drops below
/// `minimumTableWidth`. There is no Endpoint column any more: what answered shares the Scenario cell.
@Suite("Request log columns")
struct RequestLogColumnTests {

    /// SF Mono's advance is 0.6 em, so 7.2pt a character at the 12pt figure face every mono cell
    /// uses. A literal here, not a measurement, so the tests do not share arithmetic with the view.
    private static let monoAdvanceAt12pt: CGFloat = 7.2

    /// Each cell pads `DSSpacing.sm` (8pt) on both sides inside its column.
    private static let cellPadding: CGFloat = 16

    private static func columnWidth(forMonoCharacters count: Int) -> CGFloat {
        CGFloat(count) * monoAdvanceAt12pt + cellPadding
    }

    @Test("Every fixed column has a positive width")
    func widthsArePositive() {
        for width in [LogColumns.time, LogColumns.method, LogColumns.status, LogColumns.scenario,
                      LogColumns.duration, LogColumns.size, LogColumns.minimumPath] {
            #expect(width > 0)
        }
    }

    @Test("The time column fits a 12-hour timestamp with milliseconds")
    func timeColumnFitsMilliseconds() {
        // The row draws `.hour().minute().second().secondFraction(.fractional(3))` in the mono
        // figure face. The widest reading it has to hold is a 12-hour one: "11:41:33.123 PM",
        // fifteen characters.
        #expect(LogColumns.time >= Self.columnWidth(forMonoCharacters: "11:41:33.123 PM".count))
    }

    @Test("The numeric columns fit their widest ordinary figure")
    func numericColumnsFitTheirFigures() {
        // Duration switches to seconds at 1000 ms, so "999 ms" is its widest millisecond reading.
        #expect(LogColumns.duration >= Self.columnWidth(forMonoCharacters: "999 ms".count))
        #expect(LogColumns.duration >= Self.columnWidth(forMonoCharacters: "59.9 s".count))
        // Kilobytes run to "1023.9 KB" before the unit changes to megabytes.
        #expect(LogColumns.size >= Self.columnWidth(forMonoCharacters: "1023.9 KB".count))
    }

    @Test("The scenario column is wider than the token columns beside it")
    func nameColumnIsWiderThanTokenColumns() {
        // Scenario holds a name a user typed, or the backend that answered; Method and Status hold
        // tokens of at most seven characters. It is the relationship rather than the values that
        // should survive a future re-tune.
        #expect(LogColumns.scenario > LogColumns.method)
        #expect(LogColumns.scenario > LogColumns.status)
    }

    @Test("Each minimum table width leaves exactly the minimum path")
    func minimumWidthsLeaveTheMinimumPath() {
        #expect(LogColumns.pathWidth(tableWidth: LogColumns.minimumTableWidth, compact: false)
            == LogColumns.minimumPath)
        #expect(LogColumns.pathWidth(tableWidth: LogColumns.compactMinimumTableWidth, compact: true)
            == LogColumns.minimumPath)
        // The compact table is the narrower one: it is what the pane falls back to.
        #expect(LogColumns.compactMinimumTableWidth < LogColumns.minimumTableWidth)
    }

    @Test("Path takes what the fixed columns and the inset leave")
    func pathTakesTheRemainder() {
        // Full: 128 + 64 + 84 + 150 + 84 + 84 = 594 fixed, plus 6 of inset each side.
        #expect(LogColumns.pathWidth(tableWidth: 1_000, compact: false) == 394)
        // Compact: 128 + 64 + 84 = 276 fixed, plus the same inset.
        #expect(LogColumns.pathWidth(tableWidth: 1_000, compact: true) == 712)
        // Never negative, however narrow the proposal.
        #expect(LogColumns.pathWidth(tableWidth: 0, compact: false) == 0)
        #expect(LogColumns.pathWidth(tableWidth: 0, compact: true) == 0)
    }

    @Test("The fixed columns leave a readable path at the window's floor")
    func fixedColumnsLeaveRoomForThePath() {
        // At the narrowest window the app supports the centre pane is about 548pt of content once the
        // navigator and the inspector are paid for, and a route like `/api/v1/orders/{id}` measures
        // roughly 135pt at the row's face.
        //
        // That is narrower than the full seven-column table, so the log draws its compact four there
        // — and those must still leave the path readable rather than trading it for columns the
        // compact table does not draw.
        let centrePaneAtFloor: CGFloat = 548
        #expect(centrePaneAtFloor < LogColumns.minimumTableWidth)

        let path = LogColumns.pathWidth(tableWidth: centrePaneAtFloor, compact: true)
        #expect(path == 260)
        #expect(path >= LogColumns.minimumPath)
        #expect(path >= 135)
    }
}
