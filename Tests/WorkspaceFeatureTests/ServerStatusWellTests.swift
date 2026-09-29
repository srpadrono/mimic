import Foundation
import Testing
import Domain
import DesignSystem
@testable import AppFeatures

@Suite("Server toolbar presentation")
struct ServerStatusWellTests {
    private let accountsID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("Stopped is a neutral state, while errors and pending restarts remain distinct")
    @MainActor
    func stoppedStatusIsNotAnError() {
        let configuration = ServerConfiguration(port: 8080, globalDelayMs: 0)
        let stopped = ServerStatusWell(serverState: .stopped, projectName: "Test", requestCount: 0,
                                       unmatchedCount: 0, configuration: configuration)
        let failed = ServerStatusWell(serverState: .error("Port occupied"), projectName: "Test",
                                      requestCount: 0, unmatchedCount: 0, configuration: configuration)
        let running = ServerStatusWell(serverState: .running(port: 8080), projectName: "Test",
                                       requestCount: 0, unmatchedCount: 0, configuration: configuration,
                                       boundConfiguration: configuration)
        let pending = ServerStatusWell(serverState: .running(port: 8080), projectName: "Test",
                                       requestCount: 0, unmatchedCount: 0,
                                       configuration: ServerConfiguration(port: 9090, globalDelayMs: 0),
                                       boundConfiguration: configuration)
        #expect(stopped.statusColor == DSColors.labelTertiary)
        #expect(failed.statusColor == DSColors.error)
        #expect(running.statusColor == DSColors.success)
        #expect(pending.statusColor == DSColors.warning)
        #expect(stopped.statusColor != failed.statusColor)
    }

    @Test("One configured address remains visible through every lifecycle state")
    func stableSinglePortTitle() {
        let configuration = ServerConfiguration(port: 8080, globalDelayMs: 0)
        for state: ServerState in [.stopped, .starting, .running(port: 8080), .stopping, .error("Port occupied")] {
            #expect(ServerStatusWell.summaryTitle(serverState: state, configuration: configuration,
                boundConfiguration: configuration, compact: false) == "localhost:8080")
            #expect(ServerStatusWell.summaryTitle(serverState: state, configuration: configuration,
                boundConfiguration: configuration, compact: true) == "Port 8080")
        }
    }

    @Test("The active port count excludes configured listeners awaiting restart")
    func boundListenersOwnTheSummary() {
        let bound = ServerConfiguration(port: 8080, globalDelayMs: 0, backends: [
            .init(id: accountsID, name: "Accounts", port: 8081)
        ])
        let configured = ServerConfiguration(port: 9090, globalDelayMs: 0, backends: [
            .init(id: accountsID, name: "Billing", port: 9091),
            .init(name: "Search", port: 9092)
        ])
        let listeners = ServerStatusWell.displayedBackends(serverState: .running(port: 8080),
            configuration: configured, boundConfiguration: bound)
        #expect(listeners.map(\.name) == ["Primary", "Billing"])
        #expect(listeners.map(\.localURL) == ["http://localhost:8080", "http://localhost:8081"])
        #expect(ServerStatusWell.summaryTitle(serverState: .running(port: 8080), configuration: configured,
            boundConfiguration: bound, compact: false) == "localhost · 2 ports")
        #expect(ServerStatusWell.summaryTitle(serverState: .running(port: 8080), configuration: configured,
            boundConfiguration: bound, compact: true) == "2 ports")
        #expect(ServerStatusWell.summaryTitle(serverState: .stopped, configuration: configured,
            boundConfiguration: bound, compact: true) == "3 ports")
        #expect(ServerStatusWell.requiresRestart(serverState: .running(port: 8080),
            configuration: configured, boundConfiguration: bound))
        #expect(!ServerStatusWell.requiresRestart(serverState: .stopped,
            configuration: configured, boundConfiguration: bound))
    }

    @Test("Removing a configured backend does not hide a listener that is still running")
    func removedBackendRemainsCopyableUntilRestart() {
        let bound = ServerConfiguration(port: 8080, globalDelayMs: 0, backends: [
            .init(id: accountsID, name: "Accounts", port: 8081)
        ])
        let configured = ServerConfiguration(port: 8080, globalDelayMs: 0)
        let listeners = ServerStatusWell.displayedBackends(serverState: .running(port: 8080),
            configuration: configured, boundConfiguration: bound)
        #expect(listeners.map(\.name) == ["Primary", "Accounts"])
        #expect(listeners.map(\.port) == [8080, 8081])
    }

    @Test("Without a bound snapshot only the confirmed primary listener is advertised")
    func doesNotInventActiveListeners() {
        let configured = ServerConfiguration(port: 9090, globalDelayMs: 0, backends: [
            .init(name: "Accounts", port: 9091)
        ])
        #expect(ServerStatusWell.displayedBackends(serverState: .running(port: 8080),
            configuration: configured, boundConfiguration: nil).map(\.localURL) == ["http://localhost:8080"])
    }

    @Test("No project is explicit and contains no invented address")
    func noProject() {
        #expect(ServerStatusWell.summaryTitle(serverState: .stopped, configuration: nil,
            boundConfiguration: nil, compact: false) == "No project")
        #expect(ServerStatusWell.displayedBackends(serverState: .stopped,
            configuration: nil, boundConfiguration: nil).isEmpty)
    }

    @Test("Attention takes priority over routine request counts, including compact windows")
    func statusPriority() {
        #expect(ServerStatusWell.summarySubtitle(serverState: .running(port: 8080), restartRequired: false,
            requestCount: 24, unmatchedCount: 0, compact: false) == "Running · 24 requests")
        #expect(ServerStatusWell.summarySubtitle(serverState: .running(port: 8080), restartRequired: false,
            requestCount: 1, unmatchedCount: 0, compact: false) == "Running · 1 request")
        #expect(ServerStatusWell.summarySubtitle(serverState: .running(port: 8080), restartRequired: false,
            requestCount: 24, unmatchedCount: 0, compact: true) == "Running")
        for compact in [true, false] {
            #expect(ServerStatusWell.summarySubtitle(serverState: .running(port: 8080), restartRequired: false,
                requestCount: 24, unmatchedCount: 2, compact: compact) == "Running · 2 unmatched")
            #expect(ServerStatusWell.summarySubtitle(serverState: .running(port: 8080), restartRequired: true,
                requestCount: 24, unmatchedCount: 2, compact: compact) == "Restart required")
            #expect(ServerStatusWell.summarySubtitle(serverState: .error("Port occupied"), restartRequired: false,
                requestCount: 24, unmatchedCount: 2, compact: compact) == "Server error")
        }
    }

    @Test("Lifecycle wording stays distinct")
    func lifecycleStates() {
        #expect(ServerStatusWell.shortState(.stopped) == "Stopped")
        #expect(ServerStatusWell.shortState(.starting) == "Starting…")
        #expect(ServerStatusWell.shortState(.stopping) == "Stopping…")
        #expect(ServerStatusWell.stateDescription(.error("Port occupied")) == "server error: Port occupied")
    }

    @Test("Accessible details distinguish active and pending addresses")
    func pendingDetails() {
        let bound = ServerConfiguration(port: 8080, globalDelayMs: 0)
        let configured = ServerConfiguration(port: 9090, globalDelayMs: 0)
        #expect(ServerStatusWell.backendSummary(configuration: configured, boundConfiguration: bound, isRunning: true)
            == "Listening on Primary: 8080. Configured ports: Primary: 9090. Restart required.")
        #expect(ServerStatusWell.backendSummary(configuration: bound, boundConfiguration: bound, isRunning: true)
            == "1 port listening: Primary: 8080.")
        #expect(ServerStatusWell.backendSummary(configuration: configured, boundConfiguration: nil, isRunning: false)
            == "1 port configured: Primary: 9090. Server is not running.")
    }

    @Test("The capsule's request count is short and still counts its subject")
    func shortRequestCount() {
        #expect(ServerStatusWell.requestCountShort(0) == "0 requests")
        #expect(ServerStatusWell.requestCountShort(1) == "1 request")
        #expect(ServerStatusWell.requestCountShort(24) == "24 requests")
    }

    @Test("The capsule's state word stays short where the toolbar is narrow")
    func capsuleStateTitleStaysShortWhenCompact() {
        let conflict = ServerState.error("Port 21313 is already in use.")
        #expect(ServerStatusWell.capsuleStateTitle(serverState: conflict, restartRequired: false,
                                                   conflictingPort: 21313, compact: false)
                == "Couldn\u{2019}t start: port 21313 in use")
        #expect(ServerStatusWell.capsuleStateTitle(serverState: conflict, restartRequired: false,
                                                   conflictingPort: 21313, compact: true) == "Server error")
        #expect(ServerStatusWell.capsuleStateTitle(serverState: .error("Permission denied"), restartRequired: false,
                                                   conflictingPort: nil, compact: false)
                == "Couldn\u{2019}t start: Permission denied")
        #expect(ServerStatusWell.capsuleStateTitle(serverState: .running(port: 8080), restartRequired: true,
                                                   conflictingPort: nil, compact: false) == "Restart required")
        #expect(ServerStatusWell.capsuleStateTitle(serverState: .running(port: 8080), restartRequired: true,
                                                   conflictingPort: nil, compact: true) == "Restart")
        #expect(ServerStatusWell.capsuleStateTitle(serverState: .running(port: 8080), restartRequired: false,
                                                   conflictingPort: nil, compact: true) == "Running")
    }

    @Test("A start error is cut to its first clause, and a long clause to 48 characters")
    func shortErrorKeepsTheFirstClause() {
        #expect(ServerStatusWell.shortError("Port 8080 is in use. Choose another port.") == "Port 8080 is in use")
        #expect(ServerStatusWell.shortError("Address already in use\nerrno 48") == "Address already in use")
        #expect(ServerStatusWell.shortError("Permission denied") == "Permission denied")
        let exactly48 = String(repeating: "a", count: 48)
        #expect(ServerStatusWell.shortError(exactly48) == exactly48)
        #expect(ServerStatusWell.shortError(String(repeating: "a", count: 60))
            == String(repeating: "a", count: 47) + "\u{2026}")
    }

    @Test("Traffic labels retain their subject and describe available actions")
    func trafficLabels() {
        #expect(ServerStatusWell.requestCountLabel(0) == "No requests logged")
        #expect(ServerStatusWell.requestCountLabel(1) == "1 request logged")
        #expect(ServerStatusWell.requestCountLabel(24) == "24 requests logged")
        #expect(ServerStatusWell.unmatchedLabel(1, actionable: true) == "1 unmatched request, show it")
        #expect(ServerStatusWell.unmatchedLabel(2, actionable: false) == "2 unmatched requests")
    }

    @Test("The popover says since when the server has been running, as a time of day")
    func sinceTextNamesTheStartTime() {
        let text = ServerStatusWell.sinceText(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(text.hasPrefix("since "))
        #expect(text.count > "since ".count)
        #expect(!text.contains("2023"), "only the time of day, not the date")
    }
}
