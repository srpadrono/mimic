import AppKit
import SwiftUI
import Domain
import SpecImport
import DesignSystem
import FeatureSupport

/// Import flow for a given source kind: file picker -> background parse -> review screen -> commit.
///
/// The sheet's size lives here rather than inside the workflow screen, because it is a property of
/// *presenting* the flow rather than of the flow itself.
public struct ImportView: View {
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

    public init(
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
        // The review list owns scrolling, so the footer stays reachable on a compact display.
        .frame(minWidth: DSSheetWidth.review, idealWidth: DSSheetWidth.review, minHeight: 360,
               idealHeight: preferredHeight, maxHeight: preferredHeight)
    }

    private var preferredHeight: CGFloat {
        min(640, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 120))
    }
}
