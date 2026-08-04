import Foundation
import Testing
import Domain
@testable import AppFeatures

@Suite("Naming a journey captured from a request")
@MainActor
struct JourneyCaptureNamingTests {

    static func log(_ path: String) -> RequestLog {
        RequestLog(method: .get, path: path, responseStatusCode: 200, outcome: .endpoint)
    }

    @Test("A new journey is named after the resource the request touches")
    func namesAfterTheResource() {
        #expect(AppState.journeyName(capturing: Self.log("/account-summary")) == "Account summary flow")
        #expect(AppState.journeyName(capturing: Self.log("/inbox")) == "Inbox flow")
    }

    @Test("Version and api segments are skipped, since they name no resource")
    func skipsBoilerplateSegments() {
        #expect(AppState.journeyName(capturing: Self.log("/api/v1/payments")) == "Payments flow")
        #expect(AppState.journeyName(capturing: Self.log("/v2/orders")) == "Orders flow")
    }

    @Test("Identifiers are skipped so the name describes the resource, not one row")
    func skipsIdentifiers() {
        #expect(AppState.journeyName(capturing: Self.log("/users/4821")) == "Users flow")
    }

    @Test("A query string does not leak into the name")
    func ignoresQueryString() {
        #expect(AppState.journeyName(capturing: Self.log("/inbox?page=2")) == "Inbox flow")
    }

    @Test("A path with nothing nameable still yields a usable name")
    func fallsBackGracefully() {
        #expect(AppState.journeyName(capturing: Self.log("/")) == "Captured flow")
        #expect(AppState.journeyName(capturing: Self.log("/api/v1")) == "Captured flow")
    }
}
