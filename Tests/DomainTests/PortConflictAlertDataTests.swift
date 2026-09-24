import Testing
@testable import Domain

@Suite("Port conflict suggestions")
struct PortConflictAlertDataTests {
    @Test("Suggestions skip ports already assigned to another backend")
    func skipsConfiguredListeners() {
        let alert = PortConflictAlertData(conflictingPort: 8080, avoiding: [8080, 8081, 8082])
        #expect(alert.suggestedPort == 8083)
    }

    @Test("The largest valid port has no invalid 65536 suggestion")
    func stopsAtPortBoundary() {
        #expect(PortConflictAlertData(conflictingPort: 65534).suggestedPort == 65535)
        #expect(PortConflictAlertData(conflictingPort: 65534, avoiding: [65535]).suggestedPort == nil)
        #expect(PortConflictAlertData(conflictingPort: 65535).suggestedPort == nil)
        #expect(PortConflictAlertData(conflictingPort: Int.max).suggestedPort == nil)
    }
}
