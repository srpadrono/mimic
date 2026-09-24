import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

private final class JourneyImportInstance: ControlTransport, @unchecked Sendable {
    let baseURL = URL(string: "http://127.0.0.1:8787")!

    private let lock = NSLock()
    private var received: [ControlCommand] = []
    private let answer: @Sendable (ControlCommand) -> ControlResponse

    init(answer: @escaping @Sendable (ControlCommand) -> ControlResponse) {
        self.answer = answer
    }

    var commands: [ControlCommand] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func send(_ command: ControlCommand) async throws -> ControlResponse {
        record(command)
        return answer(command)
    }

    private func record(_ command: ControlCommand) {
        lock.lock()
        defer { lock.unlock() }
        received.append(command)
    }

    func isReachable() async -> Bool { true }
}

@Suite("Journey import failures and activation")
struct JourneyImportRegressionTests {
    private static let journeyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let journey = Journey(id: journeyID, name: "Flow")
    private static let fileContents = #"{"name":"Flow","steps":[]}"#

    private static func withFile(_ body: (String) async throws -> Void) async throws {
        let path = NSTemporaryDirectory() + "mimic-journey-import-\(UUID().uuidString).json"
        try fileContents.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await body(path)
    }

    private static func run(_ arguments: [String], against instance: JourneyImportInstance) async -> Int32 {
        await ControlTransportOverride.$current.withValue(instance) {
            await MimicCommand.run(arguments: arguments)
        }
    }

    @Test("A lookup refusal other than journey.notFound does not create a journey")
    func lookupFailureDoesNotCreate() async throws {
        try await Self.withFile { path in
            let instance = JourneyImportInstance { command in
                switch command.kind {
                case .journeyGet: .failure(.noProjectOpen)
                default: .success(.init(journey: Self.journey))
                }
            }

            #expect(await Self.run(["journey", "import", path], against: instance) == 4)
            #expect(instance.commands == [.journeyGet(journey: .name("Flow"))])
        }
    }

    @Test("Creating an import activates the returned id even if another journey has its name")
    func createdJourneyActivatesByID() async throws {
        try await Self.withFile { path in
            let instance = JourneyImportInstance { command in
                switch command.kind {
                case .journeyGet: .failure(.journeyNotFound(.name("Flow")))
                case .journeyCreate: .success(.init(journey: Self.journey))
                default: .success(.message("Activated."))
                }
            }

            #expect(await Self.run(["journey", "import", path, "--activate"], against: instance) == 0)
            #expect(instance.commands == [
                .journeyGet(journey: .name("Flow")),
                .journeyCreate(name: "Flow", spec: JourneySpec(steps: [])),
                .journeyActivate(journey: .id(Self.journeyID)),
            ])
        }
    }

    @Test("Replacing an import updates the looked-up id and activates the returned id")
    func updatedJourneyActivatesByID() async throws {
        try await Self.withFile { path in
            let instance = JourneyImportInstance { command in
                switch command.kind {
                case .journeyGet, .journeyUpdate: .success(.init(journey: Self.journey))
                default: .success(.message("Activated."))
                }
            }

            #expect(await Self.run(["journey", "import", path, "--replace", "--activate"], against: instance) == 0)
            #expect(instance.commands == [
                .journeyGet(journey: .name("Flow")),
                .journeyUpdate(journey: .id(Self.journeyID), spec: JourneySpec(steps: [])),
                .journeyActivate(journey: .id(Self.journeyID)),
            ])
        }
    }

    @Test("Replacement stops if a successful lookup omits the journey to update")
    func missingLookedUpJourneyFails() async throws {
        try await Self.withFile { path in
            let instance = JourneyImportInstance { _ in .success(.message("Found.")) }

            #expect(await Self.run(["journey", "import", path, "--replace"], against: instance) == 4)
            #expect(instance.commands == [.journeyGet(journey: .name("Flow"))])
        }
    }

    @Test("A successful import without a journey cannot claim activation")
    func missingImportedJourneyFails() async throws {
        try await Self.withFile { path in
            let instance = JourneyImportInstance { command in
                switch command.kind {
                case .journeyGet: .failure(.journeyNotFound(.name("Flow")))
                default: .success(.message("Created."))
                }
            }

            #expect(await Self.run(["journey", "import", path, "--activate"], against: instance) == 4)
            #expect(instance.commands == [
                .journeyGet(journey: .name("Flow")),
                .journeyCreate(name: "Flow", spec: JourneySpec(steps: [])),
            ])
        }
    }

    @Test("A successful template add without a journey cannot claim activation")
    func missingTemplateJourneyFails() async {
        let instance = JourneyImportInstance { _ in .success(.message("Added.")) }

        #expect(await Self.run(["journey", "add-template", "session-expiry", "--activate"], against: instance) == 4)
        #expect(instance.commands == [.journeyAddTemplate(templateID: "session-expiry", name: nil)])
    }
}
