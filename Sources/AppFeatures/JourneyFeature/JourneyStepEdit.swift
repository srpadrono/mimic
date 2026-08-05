import Foundation
import Domain

/// A request to open the journey step sheet, raised by the editor and presented by the workspace.
///
/// The editor sits inside a hosted split pane and cannot present a sheet from there, so it records
/// what it wants opened and `WorkspaceView` does the presenting. Carrying the journey's id as well as
/// the step is what lets the presenter save to the right place without reaching back into the editor.
struct JourneyStepEdit: Identifiable {
    let journeyID: UUID
    /// The step being edited, or `nil` to create one.
    let step: JourneyStep?

    var id: String {
        "\(journeyID.uuidString)-\(step?.id.uuidString ?? "new")"
    }
}
