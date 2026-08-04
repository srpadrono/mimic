import AppKit
import UniformTypeIdentifiers
import Testing
import Domain
import SpecImport
@testable import AppFeatures

@Suite("ImportFeature Support")
@MainActor
struct ImportFeatureTests {
    private final class MockImportOpenPanel: ImportOpenPanel {
        var allowedContentTypes: [UTType] = []
        var allowsMultipleSelection = true
        var canChooseDirectories = true
        var panelMessage: String?
        var selectedURL: URL?
        var modalResponse: NSApplication.ModalResponse

        init(modalResponse: NSApplication.ModalResponse, selectedURL: URL? = nil) {
            self.modalResponse = modalResponse
            self.selectedURL = selectedURL
        }

        func runModal() -> NSApplication.ModalResponse {
            modalResponse
        }
    }

    private nonisolated static func makeOpenAPISpec(path: String) -> Data {
        Data(
            """
            {
              "openapi": "3.0.0",
              "info": { "title": "Fixture", "version": "1.0.0" },
              "paths": {
                "\(path)": {
                  "get": {
                    "operationId": "fixture",
                    "responses": {
                      "200": {
                        "description": "OK",
                        "content": {
                          "application/json": {
                            "schema": {
                              "type": "object",
                              "properties": {
                                "ok": { "type": "boolean" }
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
            """.utf8
        )
    }

    private func parsedCandidate(path: String) async throws -> ImportCandidate {
        let candidates = try await OpenAPIParser.parse(
            data: Self.makeOpenAPISpec(path: path),
            existingEndpoints: []
        )
        return try #require(candidates.first)
    }

    @Test("Import candidate loader reads data and forwards existing endpoints")
    func importCandidateLoader() async throws {
        let url = URL(fileURLWithPath: "/tmp/spec.json")
        let endpoints = [
            Endpoint(
                name: "Users",
                method: .get,
                path: "/users",
                scenarios: [Scenario(name: "OK", statusCode: 200)],
                activeScenarioID: nil
            ),
        ]

        let specData = Self.makeOpenAPISpec(path: "/users")
        let loaded = try await ImportCandidateLoader.load(
            url: url,
            existingEndpoints: endpoints,
            loadData: { candidateURL in
                #expect(candidateURL == url)
                return specData
            },
            parse: { [specData] data, existing in
                #expect(data == specData)
                #expect(existing.count == 1)
                #expect(existing.first?.path == "/users")
                return try await OpenAPIParser.parse(data: data, existingEndpoints: existing)
            }
        )

        #expect(loaded.count == 1)
        #expect(loaded.first?.path == "/users")
    }

    @Test("Commit action forwards candidates and dismisses afterwards")
    func importCommitAction() async throws {
        let candidates = [
            try await parsedCandidate(path: "/users"),
            try await parsedCandidate(path: "/posts"),
        ]
        var events: [String] = []

        ImportCommitAction.perform(
            candidates: candidates,
            onCommit: { committed in
                events.append("commit:\(committed.count)")
            },
            dismiss: {
                events.append("dismiss")
            }
        )

        #expect(events == ["commit:2", "dismiss"])
    }

    @Test("Import flow model commit and cancelled picker keep state consistent")
    func importFlowModelCommitAndCancel() async throws {
        let staleCandidate = try await parsedCandidate(path: "/stale")
        let model = ImportWorkflow(
            candidates: [staleCandidate],
            parseError: "Old error",
            isParsing: false
        )
        var committedPaths: [String] = []
        var dismissCount = 0

        model.commit(
            onCommit: { committedPaths = $0.map(\.path) },
            dismiss: { dismissCount += 1 }
        )

        #expect(committedPaths == ["/stale"])
        #expect(dismissCount == 1)

        let cancelPanel = MockImportOpenPanel(modalResponse: .cancel)
        model.chooseFile(
            using: cancelPanel,
            existingEndpoints: [],
            loadData: { _ in
                Issue.record("loadData should not be called for a cancelled picker")
                return Data()
            }
        )

        #expect(model.candidates.count == 1)
        #expect(model.parseError == "Old error")
        #expect(model.isParsing == false)
    }
}
