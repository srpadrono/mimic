import Foundation
import Testing
@testable import AppFeatures

/// The request log's column widths.
///
/// These were `private` and therefore unasserted, which is how five of them came to be sized for
/// content the columns no longer hold. The header cells and the row cells read the same constants —
/// that is what keeps a column heading over its own column — so the value being in one place is the
/// property worth protecting, and these cases protect the *reasoning* attached to each number rather
/// than restating the number itself.
@Suite("Request log columns")
struct RequestLogColumnTests {

    @Test("Every fixed column has a positive width")
    func widthsArePositive() {
        for width in [LogColumns.method, LogColumns.endpoint, LogColumns.scenario,
                      LogColumns.status, LogColumns.time] {
            #expect(width > 0)
        }
    }

    @Test("The time column fits a 12-hour timestamp with seconds")
    func timeColumnFitsSeconds() {
        // The row draws `.dateTime.hour().minute().second()` at `DSTypography.Figure.small`, which is
        // SF Mono 11pt with monospaced digits. The widest thing that column has to hold is a
        // 12-hour reading — "11:41:33 PM", eleven characters — and SF Mono advances 0.6em, so 11pt
        // gives 6.6pt per character.
        //
        // This is the assertion the column was missing when seconds were added: the previous 58
        // fitted "9:41 AM" and would have clipped the string it now draws.
        let widestTimestamp = 11
        let advanceAt11pt = 6.6
        #expect(LogColumns.time >= CGFloat(widestTimestamp) * advanceAt11pt)
    }

    @Test("The two name columns are wider than the token columns beside them")
    func nameColumnsAreWiderThanTokenColumns() {
        // `endpoint` and `scenario` hold names a user typed; `method` and `status` hold tokens of at
        // most seven and three characters. The names being the narrower of the two was the state
        // this rebalance corrected, and it is the relationship rather than the values that should
        // survive a future re-tune.
        #expect(LogColumns.endpoint > LogColumns.method)
        #expect(LogColumns.endpoint > LogColumns.status)
        #expect(LogColumns.scenario > LogColumns.status)
    }

    @Test("The fixed columns leave a readable path at the window's floor")
    func fixedColumnsLeaveRoomForThePath() {
        // Path is the only flexible column, so every point the fixed five take is one it cannot
        // have. At the narrowest window the app supports the centre pane is about 548pt of content
        // once the navigator, the inspector and the row's own insets are paid for, and a route like
        // `/api/v1/orders/{id}` measures roughly 135pt at the row's face.
        //
        // The check is that widening the name columns did not quietly make the path unreadable at
        // the floor — which is the failure mode of tuning a fixed column while looking at a wide
        // window.
        let fixed = LogColumns.method + LogColumns.endpoint + LogColumns.scenario
            + LogColumns.status + LogColumns.time
        let centrePaneAtFloor: CGFloat = 548
        #expect(centrePaneAtFloor - fixed >= 130)
    }
}
