import AppKit
import UniformTypeIdentifiers
import Observation
import SwiftUI
import Domain
import DesignSystem
import SpecImport

protocol ImportOpenPanel: AnyObject {
    var allowedContentTypes: [UTType] { get set }
    var allowsMultipleSelection: Bool { get set }
    var canChooseDirectories: Bool { get set }
    var panelMessage: String? { get set }
    var selectedURL: URL? { get }

    func runModal() -> NSApplication.ModalResponse
}

extension NSOpenPanel: ImportOpenPanel {
    var selectedURL: URL? { url }

    var panelMessage: String? {
        get { message }
        set { message = newValue ?? "" }
    }
}

enum ImportKind: Sendable {
    case har
    case openAPI

    var title: String {
        switch self {
        case .har: "Import from HAR"
        case .openAPI: "Import from OpenAPI"
        }
    }

    var parsingMessage: String {
        switch self {
        case .har: "Parsing HAR file\u{2026}"
        case .openAPI: "Parsing OpenAPI spec\u{2026}"
        }
    }

    var emptyHeading: String {
        switch self {
        case .har: "No HAR file loaded"
        case .openAPI: "No OpenAPI spec loaded"
        }
    }

    /// The glyph the empty state opens with. Both import flows used to have none, so the two screens
    /// were distinguishable only by reading them — and `DSEmptyState`'s icon is, in its own words,
    /// the fastest way to tell which empty state you are looking at.
    var emptySystemImage: String {
        switch self {
        case .har: "doc.text.magnifyingglass"
        case .openAPI: "curlybraces"
        }
    }

    var emptyMessage: String {
        switch self {
        case .har:
            "Select a HAR file exported from Charles, Proxyman, or browser DevTools."
        case .openAPI:
            "Select an OpenAPI v3 or Swagger 2 spec, as JSON. Each operation becomes a mock endpoint."
        }
    }

    var emptyActionTitle: String {
        switch self {
        case .har: "Choose HAR file"
        case .openAPI: "Choose OpenAPI file"
        }
    }

    var cancelAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.cancelButton"
        case .openAPI: "openAPIImport.cancelButton"
        }
    }

    var parsingAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.parsing"
        case .openAPI: "openAPIImport.parsing"
        }
    }

    var errorAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.error"
        case .openAPI: "openAPIImport.error"
        }
    }

    var emptyAccessibilityIdentifier: String {
        switch self {
        case .har: "harImport.empty"
        case .openAPI: "openAPIImport.empty"
        }
    }

    var rootAccessibilityIdentifier: String {
        switch self {
        case .har: "harImportView"
        case .openAPI: "openAPIImportView"
        }
    }

    func configure(panel: any ImportOpenPanel) {
        switch self {
        case .har:
            ImportPanelSelection.configureHAR(panel: panel)
        case .openAPI:
            ImportPanelSelection.configureOpenAPI(panel: panel)
        }
    }

    func parse(
        data: Data,
        existingEndpoints: [Endpoint]
    ) async throws -> [ImportCandidate] {
        switch self {
        case .har:
            try await HARParser.parse(data: data, existingEndpoints: existingEndpoints)
        case .openAPI:
            try await OpenAPIParser.parse(data: data, existingEndpoints: existingEndpoints)
        }
    }
}

struct ImportWorkflowState {
    var candidates: [ImportCandidate]
    var parseError: String?
    var isParsing: Bool

    init(
        candidates: [ImportCandidate] = [],
        parseError: String? = nil,
        isParsing: Bool = false
    ) {
        self.candidates = candidates
        self.parseError = parseError
        self.isParsing = isParsing
    }
}

@MainActor
@Observable
final class ImportWorkflow {
    let kind: ImportKind
    var candidates: [ImportCandidate]
    var parseError: String?
    var isParsing: Bool

    /// The parse the screen is currently waiting for.
    ///
    /// It used to be an unstructured `Task` owned by nothing, which is a last-writer-wins race:
    /// choose a large HAR, realise it was the wrong file, choose a small one, and the first parse
    /// finishes second and replaces the candidates for the file you actually asked for — under a
    /// screen that had already stopped saying it was parsing, so nothing on it suggests the list is
    /// from the abandoned file. Held here so a new parse can supersede the old one.
    private(set) var parseTask: Task<Void, Never>?

    /// Which parse the state on screen belongs to.
    ///
    /// Cancelling the task above cannot do this job on its own, twice over. Cancellation is
    /// cooperative and nothing downstream observes it: `loadData` defaults to a synchronous
    /// `Data(contentsOf:)`, and `HARParser.parse` and `OpenAPIParser.parse` each decode inside a
    /// `Task.detached` of their own, which does not inherit cancellation from the task awaiting it.
    /// And even where cancellation *is* observed, awaiting a cancelled task still hands back whatever
    /// it computed, so a stale result would arrive and be committed regardless. The generation is
    /// checked at the only point that settles it — after the await, immediately before the write.
    private var parseGeneration = 0

    init(
        kind: ImportKind = .har,
        candidates: [ImportCandidate] = [],
        parseError: String? = nil,
        isParsing: Bool = false
    ) {
        self.kind = kind
        self.candidates = candidates
        self.parseError = parseError
        self.isParsing = isParsing
    }

    convenience init(kind: ImportKind = .har, state: ImportWorkflowState) {
        self.init(
            kind: kind,
            candidates: state.candidates,
            parseError: state.parseError,
            isParsing: state.isParsing
        )
    }

    func beginParsing() {
        isParsing = true
        parseError = nil
        candidates = []
    }

    func finishParsing(with parsed: [ImportCandidate]) {
        candidates = parsed
        parseError = nil
        isParsing = false
    }

    func failParsing(_ error: Error) {
        parseError = Self.readableParseError(error, kind: kind)
        isParsing = false
    }

    /// Says what the app wanted, because the error on its own does not.
    ///
    /// A decoding failure surfaces as `NSCocoaErrorDomain`'s "The data couldn't be read because it
    /// isn't in the correct format" — true of a truncated file, a YAML spec, an HTML error page saved
    /// with the wrong extension, and a JSON document that simply is not a spec. Shown alone under the
    /// heading "Parse error" it tells you nothing you did not already know, and there is no obvious
    /// next move. Naming the format that was expected turns it into something you can act on.
    static func readableParseError(_ error: Error, kind: ImportKind) -> String {
        let underlying = error.localizedDescription
        switch kind {
        case .har:
            return "\(underlying)\n\nMimic reads HAR 1.2, as exported by Charles, Proxyman or a "
                + "browser's network inspector."
        case .openAPI:
            return "\(underlying)\n\nMimic reads OpenAPI v3 and Swagger 2 as JSON. A spec written in "
                + "YAML has to be converted first."
        }
    }

    func chooseFile(
        using panel: any ImportOpenPanel = NSOpenPanel(),
        existingEndpoints: [Endpoint],
        loadData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        chooseFile(
            for: kind,
            using: panel,
            existingEndpoints: existingEndpoints,
            loadData: loadData,
            parse: { [kind] data, endpoints in
                try await kind.parse(data: data, existingEndpoints: endpoints)
            }
        )
    }

    func parseFile(
        at url: URL,
        existingEndpoints: [Endpoint],
        loadData: @escaping @Sendable (URL) throws -> Data,
        parse: @escaping @Sendable (Data, [Endpoint]) async throws -> [ImportCandidate]
    ) {
        beginParsing()

        parseGeneration &+= 1
        let generation = parseGeneration
        // Best effort, and honestly so — see `parseGeneration` for why nothing downstream stops. It
        // costs one line, and it starts working the day a parser learns to check `Task.isCancelled`.
        parseTask?.cancel()

        parseTask = Task { @MainActor [weak self, existingEndpoints, loadData, parse] in
            let outcome: Result<[ImportCandidate], any Error>
            do {
                // The detached hop is kept from the code this replaced, deliberately: this type is
                // `@MainActor`, and `ImportCandidateLoader.load` calls `loadData` — synchronous, and
                // over a file the importer allows to be 256 MB. That read must not happen on the main
                // actor, whatever else moves around it.
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try await ImportCandidateLoader.load(
                        url: url,
                        existingEndpoints: existingEndpoints,
                        loadData: loadData,
                        parse: parse
                    )
                }.value
                outcome = .success(parsed)
            } catch {
                outcome = .failure(error)
            }

            // One guard covering both outcomes, placed after the await and before anything is
            // written: a superseded parse must not report a failure either. Its error belongs to a
            // file the user has already moved on from, and showing it would replace the running
            // spinner with "Parse error" for a parse that is still going.
            guard let self, generation == parseGeneration else { return }
            switch outcome {
            case let .success(parsed):
                finishParsing(with: parsed)
            case let .failure(error):
                failParsing(error)
            }
        }
    }

    func commit(onCommit: ([ImportCandidate]) -> Void, dismiss: () -> Void) {
        ImportCommitAction.perform(candidates: candidates, onCommit: onCommit, dismiss: dismiss)
    }

    func commitAction(onCommit: @escaping ([ImportCandidate]) -> Void, dismiss: @escaping () -> Void) -> () -> Void {
        { self.commit(onCommit: onCommit, dismiss: dismiss) }
    }

    private func chooseFile(
        for kind: ImportKind,
        using panel: any ImportOpenPanel,
        existingEndpoints: [Endpoint],
        loadData: @escaping @Sendable (URL) throws -> Data,
        parse: @escaping @Sendable (Data, [Endpoint]) async throws -> [ImportCandidate]
    ) {
        kind.configure(panel: panel)
        guard let url = ImportPanelSelection.selectedURL(from: panel) else {
            return
        }

        parseFile(
            at: url,
            existingEndpoints: existingEndpoints,
            loadData: loadData,
            parse: parse
        )
    }
}

struct ImportWorkflowScreen: View {
    let kind: ImportKind
    let existingEndpoints: [Endpoint]
    let onCommitImport: ([ImportCandidate]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workflow: ImportWorkflow

    init(
        kind: ImportKind,
        existingEndpoints: [Endpoint],
        initialState: ImportWorkflowState,
        onCommitImport: @escaping ([ImportCandidate]) -> Void
    ) {
        self.kind = kind
        self.existingEndpoints = existingEndpoints
        self.onCommitImport = onCommitImport
        _workflow = State(initialValue: ImportWorkflow(kind: kind, state: initialState))
    }

    var body: some View {
        @Bindable var workflow = workflow

        VStack(spacing: 0) {
            // A sheet heading at `DSTypography.title`, *not* a `DSPanelHeader`, and deliberately so.
            // This is the shared sheet convention — `NewProjectSheet`, `NewJourneySheet`,
            // `JourneyTemplatePicker` and `JourneyStepSheet` all open with a sentence-case 20pt
            // heading — and a modal you have just opened from a menu needs a title that says what it
            // is, which a 10pt `labelSecondary` caption does not. The decisive part is what sits
            // directly beneath: `ImportReviewList` opens with a real `DSPanelHeader` ("Endpoints
            // found"), so making this one too would stack two identical 30pt caption bars and leave
            // the sheet with no title at all.
            HStack(spacing: DSSpacing.sm) {
                Text(kind.title)
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)
                Spacer(minLength: DSSpacing.sm)
                // `.medium`, like the cancel button in every other sheet and like this screen's own
                // "Import n endpoints" in the footer. At `.small` it was a 20pt control beside a 20pt
                // heading, which read as undersized and gave the escape action the smallest hit
                // target on the screen.
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "\(kind.rootAccessibilityIdentifier).cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier(kind.cancelAccessibilityIdentifier)
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)
            }
            .padding(DSSpacing.md)

            DSDivider(identifier: "\(kind.rootAccessibilityIdentifier).header")

            if workflow.isParsing {
                ProgressView(kind.parsingMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(kind.parsingAccessibilityIdentifier)
            } else if let error = workflow.parseError {
                // No `Spacer()` above and below. `DSEmptyState` already claims
                // `.frame(maxHeight: .infinity)` and centres itself inside it, so a `Spacer` either
                // side gave three equally flexible children one third of the sheet each — and one
                // third of a 560pt sheet is less than the icon, heading, message and button need, so
                // the state that exists to explain a failure was the one squeezed out of room.
                DSEmptyState(
                    systemImage: "exclamationmark.triangle",
                    heading: "Parse error",
                    message: error,
                    actionTitle: "Choose another file",
                    identifier: kind.errorAccessibilityIdentifier,
                    // The sheet's only action, so Return has to reach it. Without this the import
                    // sheets answered neither Return nor Tab: a modal whose one control could only
                    // be hit with a mouse.
                    isDefaultAction: true
                ) {
                    workflow.chooseFile(existingEndpoints: existingEndpoints)
                }
            } else if workflow.candidates.isEmpty {
                DSEmptyState(
                    systemImage: kind.emptySystemImage,
                    heading: kind.emptyHeading,
                    message: kind.emptyMessage,
                    actionTitle: kind.emptyActionTitle,
                    identifier: kind.emptyAccessibilityIdentifier,
                    isDefaultAction: true
                ) {
                    workflow.chooseFile(existingEndpoints: existingEndpoints)
                }
            } else {
                ImportReviewList(
                    candidates: $workflow.candidates,
                    onImport: workflow.commitAction(onCommit: onCommitImport, dismiss: dismiss.callAsFunction)
                )
            }
        }
        .frame(minWidth: 600, minHeight: 450)
        // Paired, or this one identifier renames every control in the import sheet — the cancel
        // button, the select-all pair, and all two hundred candidate toggles would each report
        // "harImportView" and none of them would be addressable. Still correct: this container holds
        // several addressable things, which is exactly the case that needs `.contain`. Nothing
        // between here and them masks a child either — `DSEmptyState` and `ImportReviewList`'s
        // candidate list pair their own container identifiers, and the cancel button and the
        // progress view are leaves whose identifiers are the ones a test looks for.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(kind.rootAccessibilityIdentifier)
    }
}

enum ImportPanelSelection {
    /// The fallback is not defensive padding. This asks the system to describe a filename extension,
    /// which is a question it is allowed to have no answer to — that is why the initialiser is
    /// failable — and the `!` that used to be here turned "open the HAR importer" into a crash the
    /// user could do nothing about, over a value that decides a picker filter and nothing else. A HAR
    /// *is* JSON, so `.json` degrades to a panel that still filters rather than to no panel at all.
    static func configureHAR(panel: any ImportOpenPanel) {
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.panelMessage = "Choose a HAR file to import"
    }

    /// JSON only, because JSON is all `OpenAPIParser` can read — it is a `JSONDecoder`.
    ///
    /// `.yaml` and `.yml` used to be offered here, and could never work. A YAML spec is the common
    /// case, so the effect was that the file most people have was presented as selectable, accepted,
    /// and then refused with Foundation's "The data couldn't be read because it isn't in the correct
    /// format" — which names neither the cause nor the remedy. Offering a type the parser cannot read
    /// is the bug; greying it out at least says so before the click.
    ///
    /// Reading YAML is a feature, not a fix, and it needs a parser this app does not link.
    static func configureOpenAPI(panel: any ImportOpenPanel) {
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.panelMessage = "Choose an OpenAPI v3 spec file"
    }

    static func selectedURL(from panel: any ImportOpenPanel) -> URL? {
        guard panel.runModal() == .OK, let url = panel.selectedURL else {
            return nil
        }

        return url
    }
}

enum ImportCandidateLoader {
    /// Largest file the importer will read (256 MB).
    ///
    /// A HAR is decoded whole — `JSONDecoder` over the entire document — so the file's size is the
    /// app's memory. The cap is well above any real capture (a busy hour of traffic is single-digit
    /// megabytes) and low enough that pointing the importer at the wrong file gives a message instead
    /// of a spinner and a beachball.
    static let maxFileSizeBytes = 256 * 1024 * 1024

    static func load(
        url: URL,
        existingEndpoints: [Endpoint],
        loadData: @Sendable (URL) throws -> Data,
        parse: @Sendable (Data, [Endpoint]) async throws -> [ImportCandidate]
    ) async throws -> [ImportCandidate] {
        try checkSize(of: url)
        let data = try loadData(url)
        return try await parse(data, existingEndpoints)
    }

    /// Checked from the filesystem before the bytes are read, so an oversized file is never loaded.
    /// An unreadable size is not itself an error — the read that follows will produce a better one.
    static func checkSize(of url: URL, fileManager: FileManager = .default) throws {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return
        }
        guard size <= maxFileSizeBytes else {
            throw ImportSizeError.tooLarge(bytes: size, limit: maxFileSizeBytes)
        }
    }
}

enum ImportSizeError: Error, LocalizedError, Equatable {
    case tooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes, limit):
            let formatter = ByteCountFormatter()
            return "That file is \(formatter.string(fromByteCount: Int64(bytes))), "
                + "over the \(formatter.string(fromByteCount: Int64(limit))) import limit. "
                + "Trim the capture, or split it into smaller files."
        }
    }
}

enum ImportCommitAction {
    static func perform(
        candidates: [ImportCandidate],
        onCommit: ([ImportCandidate]) -> Void,
        dismiss: () -> Void
    ) {
        onCommit(candidates)
        dismiss()
    }
}
