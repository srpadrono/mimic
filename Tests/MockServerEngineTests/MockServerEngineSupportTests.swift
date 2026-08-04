import Testing
import Domain
@testable import MockServerEngine

@Suite("MockServerEngine Support")
struct MockServerEngineSupportTests {
    @Test("MockServerError descriptions are stable")
    func mockServerErrorDescriptions() {
        #expect(MockServerError.portInUse(port: 8080).errorDescription == "Port 8080 is already in use.")
        #expect(MockServerError.alreadyRunning.errorDescription == "Server is already running.")
        #expect(MockServerError.notRunning.errorDescription == "Server is not running.")
        #expect(
            MockServerError.invalidState(.starting).errorDescription
                == "Cannot perform operation in state: starting."
        )
    }
}
