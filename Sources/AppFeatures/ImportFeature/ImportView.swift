import SwiftUI
import Domain
import SpecImport

/// Import flow for a given source kind: file picker -> background parse -> review screen -> commit.
///
/// The sheet's size lives here rather than inside the workflow screen, because it is a property of
/// *presenting* the flow rather than of the flow itself.
struct ImportView: View {
    let kind: ImportKind
    let existingEndpoints: [Endpoint]
    let initialState: ImportWorkflowState
    let onCommitImport: ([ImportCandidate]) -> Void

    public init(
        kind: ImportKind,
        existingEndpoints: [Endpoint],
        onCommitImport: @escaping ([ImportCandidate]) -> Void
    ) {
        self.init(
            kind: kind,
            existingEndpoints: existingEndpoints,
            initialCandidates: [],
            initialParseError: nil,
            initialIsParsing: false,
            onCommitImport: onCommitImport
        )
    }

    init(
        kind: ImportKind,
        existingEndpoints: [Endpoint],
        initialCandidates: [ImportCandidate],
        initialParseError: String?,
        initialIsParsing: Bool,
        onCommitImport: @escaping ([ImportCandidate]) -> Void
    ) {
        self.kind = kind
        self.existingEndpoints = existingEndpoints
        self.initialState = ImportWorkflowState(
            candidates: initialCandidates,
            parseError: initialParseError,
            isParsing: initialIsParsing
        )
        self.onCommitImport = onCommitImport
    }

    public var body: some View {
        ImportWorkflowScreen(
            kind: kind,
            existingEndpoints: existingEndpoints,
            initialState: initialState,
            onCommitImport: onCommitImport
        )
        // The screen inside asks for 600×450. That is a dialog, and this is a table: a real HAR is
        // two hundred entries, and at 450pt the review showed about a dozen of them at a time while
        // its own chrome took a fifth of the height. The floor is raised here rather than in the
        // screen so the workflow view stays presentable in a smaller container if one ever needs it.
        .frame(minWidth: 760, minHeight: 560)
    }
}
