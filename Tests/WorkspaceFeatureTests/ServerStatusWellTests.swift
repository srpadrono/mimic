import SwiftUI
import Testing
import Domain
@testable import AppFeatures

@Suite("Server status well")
struct ServerStatusWellTests {

    // MARK: - What the well says

    @Test("A running server shows its address instead of the project name")
    func showsAddressWhileRunning() {
        // No scheme: the well is toolbar-width, and `http://` is seven characters that never vary.
        #expect(
            ServerStatusWell.primaryText(serverState: .running(port: 8080), projectName: "Payments API")
                == "localhost:8080"
        )
    }

    @Test("A server that is not running says so, rather than repeating the window title")
    func namesTheServerStateWhileNotRunning() {
        // The project name is already in the title bar a centimetre away. Echoing it here read as a
        // rendering fault and answered none of the questions the well exists to answer.
        func text(_ state: ServerState) -> String {
            ServerStatusWell.primaryText(serverState: state, projectName: "Payments API")
        }

        #expect(text(.stopped) == "Server stopped")
        #expect(text(.starting) == "Starting\u{2026}")
        #expect(text(.stopping) == "Stopping\u{2026}")
        #expect(text(.error("Port 8080 in use")) == "Server error")
    }

    @Test("With no project the well says so rather than going blank")
    func namesTheAbsenceOfAProject() {
        #expect(ServerStatusWell.primaryText(serverState: .stopped, projectName: nil) == "No project")
        // A name that is only whitespace would render as an empty capsule, which reads as a glitch.
        #expect(ServerStatusWell.primaryText(serverState: .stopped, projectName: "   ") == "No project")
        #expect(ServerStatusWell.primaryText(serverState: .stopped, projectName: "") == "No project")
    }

    // MARK: - What a click copies

    @Test("The copied URL keeps the scheme the display drops")
    func copiesAFullURL() {
        #expect(ServerStatusWell.copyableURL(serverState: .running(port: 3000)) == "http://localhost:3000")
        #expect(ServerStatusWell.primaryText(serverState: .running(port: 3000), projectName: nil)
            == "localhost:3000")
    }

    @Test("Nothing is copyable unless a port is actually listening")
    func hasNothingToCopyWhenNotRunning() {
        // The affordance is driven off this being nil, so a stopped server cannot hand out an address
        // that answers nothing.
        #expect(ServerStatusWell.copyableURL(serverState: .stopped) == nil)
        #expect(ServerStatusWell.copyableURL(serverState: .starting) == nil)
        #expect(ServerStatusWell.copyableURL(serverState: .stopping) == nil)
        #expect(ServerStatusWell.copyableURL(serverState: .error("Port 8080 in use")) == nil)
    }

    // MARK: - What VoiceOver hears

    @Test("Each server state has a spoken description")
    func describesEveryState() {
        #expect(ServerStatusWell.stateDescription(.stopped) == "server stopped")
        #expect(ServerStatusWell.stateDescription(.starting) == "server starting")
        #expect(ServerStatusWell.stateDescription(.running(port: 8080)) == "server running")
        #expect(ServerStatusWell.stateDescription(.stopping) == "server stopping")
        #expect(ServerStatusWell.stateDescription(.error("Port 8080 in use"))
            == "server error: Port 8080 in use")
    }

    @Test("A running well announces the address and that it can be copied")
    func announcesTheCopyAffordance() {
        #expect(
            ServerStatusWell.primaryAccessibilityLabel(
                serverState: .running(port: 8080),
                projectName: "Payments API"
            ) == "Server base URL http://localhost:8080, click to copy"
        )
    }

    @Test("A stopped well announces the project and the state, not a copy affordance")
    func announcesProjectAndStateWhenStopped() {
        #expect(
            ServerStatusWell.primaryAccessibilityLabel(serverState: .stopped, projectName: "Payments API")
                == "Payments API, server stopped"
        )
        #expect(
            ServerStatusWell.primaryAccessibilityLabel(serverState: .starting, projectName: nil)
                == "No project, server starting"
        )
        #expect(
            ServerStatusWell.primaryAccessibilityLabel(
                serverState: .error("Port 8080 in use"),
                projectName: "Payments API"
            ) == "Payments API, server error: Port 8080 in use"
        )
    }

    @Test("Request counts are spoken as sentences rather than as a bare number")
    func speaksRequestCounts() {
        #expect(ServerStatusWell.requestCountLabel(0) == "No requests logged")
        #expect(ServerStatusWell.requestCountLabel(1) == "1 request logged")
        #expect(ServerStatusWell.requestCountLabel(12) == "12 requests logged")
    }

    @Test("The unmatched badge only promises a jump when one is wired up")
    func speaksUnmatchedCounts() {
        // `onShowUnmatched` is optional, so the label has to stop offering "show them" when nothing
        // will happen on click.
        #expect(ServerStatusWell.unmatchedLabel(3, actionable: true) == "3 unmatched requests, show them")
        #expect(ServerStatusWell.unmatchedLabel(1, actionable: true) == "1 unmatched request, show it")
        #expect(ServerStatusWell.unmatchedLabel(3, actionable: false) == "3 unmatched requests")
        #expect(ServerStatusWell.unmatchedLabel(1, actionable: false) == "1 unmatched request")
    }

    // MARK: - The tooltip

    @Test("The tooltip explains the address, the traffic, and the warning")
    func explainsARunningWell() {
        let help = ServerStatusWell.helpText(
            serverState: .running(port: 8080),
            projectName: "Payments API",
            requestCount: 12,
            unmatchedCount: 3
        )

        #expect(help == """
        Server running at http://localhost:8080. Click the address to copy it. \
        12 requests logged. 3 matched no endpoint or journey.
        """)
    }

    @Test("The tooltip drops the unmatched sentence when nothing is unmatched")
    func explainsAStoppedWell() {
        let help = ServerStatusWell.helpText(
            serverState: .stopped,
            projectName: "Payments API",
            requestCount: 0,
            unmatchedCount: 0
        )

        #expect(help == "Payments API — server stopped. No requests logged.")
        #expect(!help.contains("unmatched"))
    }

    @Test("The tooltip still names the state when there is no project and no traffic")
    func explainsAnEmptyWell() {
        #expect(
            ServerStatusWell.helpText(
                serverState: .error("Port 8080 in use"),
                projectName: nil,
                requestCount: 0,
                unmatchedCount: 0
            ) == "No project — server error: Port 8080 in use. No requests logged."
        )
    }
}
