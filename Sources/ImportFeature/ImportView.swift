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
    let height: CGFloat?

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

    /// - Parameter initialSourceFileName: The file the initial candidates came from.
    /// - Parameter initialHiddenHosts: Hosts the review starts with switched off.
    /// - Parameter height: A fixed height, for a rendering that must not depend on the screen.
    public init(
        kind: ImportKind,
        existingEndpoints: [Endpoint],
        initialCandidates: [ImportCandidate],
        initialParseError: String?,
        initialIsParsing: Bool,
        initialSourceFileName: String? = nil,
        initialHiddenHosts: Set<String> = [],
        height: CGFloat? = nil,
        onCommitImport: @escaping ([ImportCandidate]) -> Void
    ) {
        self.kind = kind
        self.existingEndpoints = existingEndpoints
        self.initialState = ImportWorkflowState(
            candidates: initialCandidates,
            parseError: initialParseError,
            isParsing: initialIsParsing,
            sourceFileName: initialSourceFileName,
            hiddenHosts: initialHiddenHosts
        )
        self.onCommitImport = onCommitImport
        self.height = height
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

    /// The design's height, on any screen tall enough to show it with room to spare.
    public static let designHeight: CGFloat = 696

    private var preferredHeight: CGFloat {
        if let height { return height }
        return Self.preferredHeight(visibleScreenHeight: ScreenMetrics.visibleHeight(of: NSScreen.main) ?? 900)
    }

    static func preferredHeight(visibleScreenHeight: CGFloat) -> CGFloat {
        min(designHeight, max(360, visibleScreenHeight - 120))
    }
}
