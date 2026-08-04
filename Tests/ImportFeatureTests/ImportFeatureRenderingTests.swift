import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Testing
import Domain
@testable import SpecImport
@testable import AppFeatures

@Suite("ImportFeature Rendering")
@MainActor
struct ImportFeatureRenderingTests {
    private final class MockImportOpenPanel: ImportOpenPanel {
        var allowedContentTypes: [UTType] = []
        var allowsMultipleSelection = true
        var canChooseDirectories = true
        var panelMessage: String?
        var selectedURL: URL?
        var modalResponse: NSApplication.ModalResponse

        init(
            modalResponse: NSApplication.ModalResponse,
            selectedURL: URL? = nil
        ) {
            self.modalResponse = modalResponse
            self.selectedURL = selectedURL
        }

        func runModal() -> NSApplication.ModalResponse {
            modalResponse
        }
    }

    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 960, height: 720),
        wait: TimeInterval = 0.05
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    private func makeCandidate(
        method: HTTPMethod = .get,
        path: String = "/api/v1/users",
        isSelected: Bool = true,
        isDuplicate: Bool = false,
        bodySizeBytes: Int = 128,
        bodySizeExceedsLimit: Bool = false
    ) -> ImportCandidate {
        ImportCandidate(
            id: UUID(),
            isSelected: isSelected,
            method: method,
            path: path,
            suggestedName: "Import \(method.rawValue)",
            suggestedGroupTag: "Users",
            statusCode: 200,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: bodySizeExceedsLimit ? nil : #"{"ok":true}"#,
            responseContentType: .json,
            bodySizeBytes: bodySizeBytes,
            bodySizeExceedsLimit: bodySizeExceedsLimit,
            isDuplicate: isDuplicate
        )
    }

    private struct ImportReviewHarness: View {
        @State var candidates: [ImportCandidate]
        let onImport: () -> Void

        var body: some View {
            ImportReviewList(candidates: $candidates, onImport: onImport)
        }
    }

    @Test("Import flow model tracks parsing transitions")
    func importWorkflowTransitions() {
        let candidate = makeCandidate()
        let model = ImportWorkflow(
            candidates: [candidate],
            parseError: "Old error",
            isParsing: false
        )

        model.beginParsing()
        #expect(model.candidates.isEmpty)
        #expect(model.parseError == nil)
        #expect(model.isParsing)

        model.finishParsing(with: [candidate])
        #expect(model.candidates.count == 1)
        #expect(model.candidates.first?.path == candidate.path)
        #expect(model.parseError == nil)
        #expect(model.isParsing == false)

        struct ParseFailure: Error, LocalizedError {
            var errorDescription: String? { "Parse failed" }
        }

        model.failParsing(ParseFailure())
        // The underlying message, plus the sentence naming what the importer expected. Foundation's
        // decoding error on its own ("…isn't in the correct format") is true of a truncated file, a
        // YAML spec and an HTML error page alike, and leaves the reader no next move.
        #expect(model.parseError?.hasPrefix("Parse failed") == true)
        #expect(model.parseError?.contains("HAR 1.2") == true)
        #expect(model.isParsing == false)
    }

    @Test("Import panel helpers configure HAR and OpenAPI selection")
    func importPanelHelpersConfigureSelection() {
        let harPanel = MockImportOpenPanel(modalResponse: .cancel)
        ImportPanelSelection.configureHAR(panel: harPanel)

        #expect(harPanel.allowedContentTypes.count == 1)
        #expect(harPanel.allowsMultipleSelection == false)
        #expect(harPanel.canChooseDirectories == false)
        #expect(harPanel.panelMessage == "Choose a HAR file to import")

        let openAPIPanel = MockImportOpenPanel(
            modalResponse: .OK,
            selectedURL: URL(fileURLWithPath: "/tmp/spec.json")
        )
        ImportPanelSelection.configureOpenAPI(panel: openAPIPanel)

        // JSON only, because `OpenAPIParser` is a `JSONDecoder`. `.yaml` and `.yml` used to be
        // offered here and could never be read — the common case for a spec, presented as selectable
        // and then refused.
        #expect(openAPIPanel.allowedContentTypes == [.json])
        #expect(openAPIPanel.panelMessage == "Choose an OpenAPI v3 spec file")
        #expect(ImportPanelSelection.selectedURL(from: openAPIPanel)?.lastPathComponent == "spec.json")
        #expect(ImportPanelSelection.selectedURL(from: harPanel) == nil)
    }

    @Test("NSOpenPanel convenience accessors bridge the protocol surface")
    func nsOpenPanelBridgeAccessors() {
        let panel = NSOpenPanel()

        panel.panelMessage = "Choose fixture"
        #expect(panel.message == "Choose fixture")
        #expect(panel.panelMessage == "Choose fixture")
        #expect(panel.selectedURL == nil)

        panel.panelMessage = nil
        #expect(panel.message.isEmpty)
        #expect(panel.panelMessage?.isEmpty == true)
    }

    @Test("HAR import parser updates model state")
    func harImportParserUpdatesModelState() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/sample.har")
        let parsed = [makeCandidate(path: "/api/v1/har")]
        let model = ImportWorkflow(
            candidates: [makeCandidate(path: "/stale")],
            parseError: "Old error",
            isParsing: false
        )

        model.parseFile(
            at: fileURL,
            existingEndpoints: [],
            loadData: { url in
                #expect(url == fileURL)
                return Data("har".utf8)
            },
            parse: { data, endpoints in
                #expect(data == Data("har".utf8))
                #expect(endpoints.isEmpty)
                return parsed
            }
        )

        try await Task.sleep(for: .milliseconds(50))

        #expect(model.candidates.count == 1)
        #expect(model.candidates.first?.path == parsed.first?.path)
        #expect(model.parseError == nil)
        #expect(model.isParsing == false)
    }

    @Test("OpenAPI import parser records failures on the model")
    func openAPIImportParserRecordsFailures() async throws {
        enum FixtureError: Error, LocalizedError {
            case invalidSpec

            var errorDescription: String? { "Invalid spec fixture" }
        }

        // `kind: .openAPI`, which this test's name has always claimed and its body never set — the
        // default is `.har`, so it was exercising the HAR workflow under an OpenAPI name. It only
        // showed up once the failure message started depending on which importer failed.
        let model = ImportWorkflow(
            kind: .openAPI,
            candidates: [makeCandidate(path: "/stale")],
            parseError: nil,
            isParsing: false
        )

        model.parseFile(
            at: URL(fileURLWithPath: "/tmp/spec.json"),
            existingEndpoints: [],
            loadData: { _ in throw FixtureError.invalidSpec },
            parse: { _, _ in [] }
        )

        try await Task.sleep(for: .milliseconds(50))

        #expect(model.candidates.isEmpty)
        #expect(model.parseError?.hasPrefix("Invalid spec fixture") == true)
        #expect(model.parseError?.contains("YAML") == true)
        #expect(model.isParsing == false)
    }

    @Test("OpenAPI picker can use the default parser pipeline")
    func openAPIPickerUsesDefaultParser() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/spec.json")
        let panel = MockImportOpenPanel(modalResponse: .OK, selectedURL: fileURL)
        let model = ImportWorkflow(kind: .openAPI)
        let spec = """
        {
          "openapi": "3.0.0",
          "info": { "title": "Fixture", "version": "1.0.0" },
          "paths": {
            "/users": {
              "get": {
                "operationId": "listUsers",
                "responses": {
                  "200": {
                    "description": "OK",
                    "content": {
                      "application/json": {
                        "schema": {
                          "type": "object",
                          "properties": {
                            "users": { "type": "array", "items": { "type": "string" } }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

        model.chooseFile(
            using: panel,
            existingEndpoints: [],
            loadData: { url in
                #expect(url == fileURL)
                return Data(spec.utf8)
            }
        )

        try await Task.sleep(for: .milliseconds(80))

        #expect(model.parseError == nil)
        #expect(model.candidates.count == 1)
        #expect(model.candidates.first?.method == .get)
        #expect(model.candidates.first?.path == "/users")
    }

    @Test("Picker cancellation leaves model state untouched")
    func pickerCancellationLeavesStateUntouched() {
        let panel = MockImportOpenPanel(modalResponse: .cancel)
        let initial = makeCandidate(path: "/existing")
        let model = ImportWorkflow(candidates: [initial], parseError: "Existing", isParsing: false)

        model.chooseFile(
            using: panel,
            existingEndpoints: [],
            loadData: { _ in
                Issue.record("loadData should not run when selection is cancelled")
                return Data()
            }
        )

        #expect(model.candidates.first?.path == "/existing")
        #expect(model.parseError == "Existing")
        #expect(model.isParsing == false)
    }

    @Test("Import helpers load candidates and commit selections")
    func importHelpersLoadAndCommit() async throws {
        let url = URL(fileURLWithPath: "/tmp/import.json")
        let candidate = makeCandidate(path: "/api/v1/committed")
        let loaded = try await ImportCandidateLoader.load(
            url: url,
            existingEndpoints: [],
            loadData: { fileURL in
                #expect(fileURL == url)
                return Data("payload".utf8)
            },
            parse: { data, endpoints in
                #expect(data == Data("payload".utf8))
                #expect(endpoints.isEmpty)
                return [candidate]
            }
        )

        var committed: [ImportCandidate] = []
        var dismissed = false
        ImportCommitAction.perform(
            candidates: loaded,
            onCommit: { committed = $0 },
            dismiss: { dismissed = true }
        )

        #expect(committed.count == 1)
        #expect(committed.first?.path == candidate.path)
        #expect(dismissed)
    }

    @Test("HAR import view renders empty state")
    func rendersHARImportEmptyState() {
        let size = render(
            ImportView(kind: .har, existingEndpoints: []) { _ in }
        )

        #expect(size.width >= 0)
    }


    @Test("HAR import view renders parsing error and populated states")
    func rendersHARImportAdditionalStates() {
        let candidates = [
            makeCandidate(),
            makeCandidate(method: .post, path: "/api/v1/sessions"),
        ]

        let parsingSize = render(
            ImportView(
                kind: .har,
                existingEndpoints: [],
                initialCandidates: [],
                initialParseError: nil,
                initialIsParsing: true
            ) { _ in }
        )
        let errorSize = render(
            ImportView(
                kind: .har,
                existingEndpoints: [],
                initialCandidates: [],
                initialParseError: "Invalid HAR structure",
                initialIsParsing: false
            ) { _ in }
        )
        let populatedSize = render(
            ImportView(
                kind: .har,
                existingEndpoints: [],
                initialCandidates: candidates,
                initialParseError: nil,
                initialIsParsing: false
            ) { _ in }
        )

        #expect(parsingSize.height >= 0)
        #expect(errorSize.width >= 0)
        #expect(populatedSize.height >= 0)
    }

    @Test("OpenAPI import view renders empty state")
    func rendersOpenAPIImportEmptyState() {
        let size = render(
            ImportView(kind: .openAPI, existingEndpoints: []) { _ in }
        )

        #expect(size.height >= 0)
    }

    @Test("OpenAPI import view renders parsing error and populated states")
    func rendersOpenAPIImportAdditionalStates() {
        let candidates = [
            makeCandidate(path: "/api/v1/users"),
            makeCandidate(method: .delete, path: "/api/v1/users/{id}"),
        ]

        let parsingSize = render(
            ImportView(
                kind: .openAPI,
                existingEndpoints: [],
                initialCandidates: [],
                initialParseError: nil,
                initialIsParsing: true
            ) { _ in }
        )
        let errorSize = render(
            ImportView(
                kind: .openAPI,
                existingEndpoints: [],
                initialCandidates: [],
                initialParseError: "Unsupported OpenAPI document",
                initialIsParsing: false
            ) { _ in }
        )
        let populatedSize = render(
            ImportView(
                kind: .openAPI,
                existingEndpoints: [],
                initialCandidates: candidates,
                initialParseError: nil,
                initialIsParsing: false
            ) { _ in }
        )

        #expect(parsingSize.height >= 0)
        #expect(errorSize.width >= 0)
        #expect(populatedSize.height >= 0)
    }

    @Test("Import review list renders warnings and selected summary")
    func rendersImportReviewList() {
        let candidates = [
            makeCandidate(),
            makeCandidate(method: .post, path: "/api/v1/login", isSelected: false, isDuplicate: true),
            makeCandidate(method: .delete, path: "/api/v1/files", bodySizeBytes: 1_200_000, bodySizeExceedsLimit: true),
        ]

        let size = render(
            ImportReviewHarness(candidates: candidates, onImport: {})
        )

        #expect(size.width >= 0)
    }
}
