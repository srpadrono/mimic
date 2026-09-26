import Foundation
import Testing
import Domain
@testable import SpecImport

@Suite("Import candidate defaults")
struct ImportCandidateBuilderTests {
    @Test("Equivalent route patterns are duplicates even when slashes or parameter names differ", arguments: [
        ("/items/", "/items"),
        ("/items/:oldID", "/items/{id}/"),
    ])
    func equivalentPatterns(existing: String, imported: String) {
        var ledger = ImportRouteLedger(existingEndpoints: [Endpoint(name: "Existing", path: existing)])
        let candidate = Self.candidate(path: imported, ledger: &ledger)
        #expect(candidate.isDuplicate)
        #expect(!candidate.isSelected)
    }

    @Test("Literal specificity, case, method, and GraphQL operations retain separate claims")
    func distinctPatternsRemainSelectable() {
        var ledger = ImportRouteLedger(existingEndpoints: [
            Endpoint(name: "Items", path: "/items/:id"),
            Endpoint(name: "Account", method: .post, path: "/graphql", graphqlOperation: "Account"),
        ])
        for candidate in [
            Self.candidate(path: "/items/me", ledger: &ledger),
            Self.candidate(path: "/Items/{id}", ledger: &ledger),
            Self.candidate(path: "/items/{id}", method: .post, ledger: &ledger),
            Self.candidate(path: "/graphql", method: .post, operation: "Payments", ledger: &ledger),
        ] {
            #expect(candidate.isSelected)
            #expect(!candidate.isDuplicate)
        }
    }

    @Test("An oversized first response does not hide a later complete capture")
    func oversizedResponseDoesNotClaimRoute() {
        var ledger = ImportRouteLedger(existingEndpoints: [])
        let large = Self.candidate(path: "/items", body: String(repeating: "a", count: 1_048_577), ledger: &ledger)
        #expect(large.bodySizeExceedsLimit)
        #expect(large.responseBody == nil)
        #expect(!large.isSelected)
        let complete = Self.candidate(path: "/items/", body: "complete", ledger: &ledger)
        #expect(complete.isSelected)
        #expect(!complete.isDuplicate)
        #expect(complete.responseBody == "complete")
    }

    @Test("Invalid retained headers do not reserve the route ahead of a valid response", arguments: [
        ["Bad Header": "value"], ["X-Test": "first\r\nInjected: second"],
    ])
    func invalidHeadersDoNotClaimRoute(headers: [String: String]) {
        var ledger = ImportRouteLedger(existingEndpoints: [])
        let invalid = Self.candidate(path: "/items", headers: headers, ledger: &ledger)
        #expect(!invalid.isSelected)
        let valid = Self.candidate(path: "/items", headers: ["X-Test": "safe"], ledger: &ledger)
        #expect(valid.isSelected)
        #expect(!valid.isDuplicate)
    }

    @Test("JSON classification uses the media type rather than an incidental substring", arguments: [
        "application/json", " Application/Problem+JSON ; charset=utf-8", "text/json",
    ])
    func jsonMediaTypes(value: String) {
        #expect(ImportCandidateBuilder.detectContentType(value) == .json)
    }

    @Test("Non-JSON formats and parameters do not turn text into JSON", arguments: [
        "text/plain; profile=json", "application/jsonp", "application/json-seq", "application/notjson", "",
    ])
    func nonJSONMediaTypes(value: String) {
        #expect(ImportCandidateBuilder.detectContentType(value) == .plainText)
    }

    @Test("A resource named v is not mistaken for an API version prefix")
    func bareVIsAResource() {
        #expect(ImportCandidateBuilder.suggestName(method: .get, path: "/v") == "Get V")
        #expect(ImportCandidateBuilder.suggestName(method: .get, path: "/api/v2/items/:id") == "Get Items")
    }

    private static func candidate(
        path: String, method: HTTPMethod = .get, body: String = "{}", headers: [String: String] = [:], operation: String? = nil,
        ledger: inout ImportRouteLedger
    ) -> ImportCandidate {
        ImportCandidateBuilder.makeCandidate(method: method, path: path, statusCode: 200,
            responseHeaders: headers, responseBody: body, responseContentType: .json,
            graphqlOperation: operation, ledger: &ledger)
    }
}
