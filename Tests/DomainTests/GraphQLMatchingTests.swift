import Foundation
import Testing
@testable import Domain

/// GraphQL routes everything through one path, so the discriminator has to come from the body.
/// These cover the shapes real clients actually send — named, anonymous, shorthand, batched — because
/// the fallback chain is the whole reason this works on traffic you did not author.
@Suite("GraphQL operation extraction")
struct GraphQLOperationTests {

    static func body(query: String, operationName: String? = nil, variables: String = "{}") -> String {
        let name = operationName.map { "\"operationName\": \"\($0)\", " } ?? ""
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "{ \(name)\"query\": \"\(escaped)\", \"variables\": \(variables) }"
    }

    // MARK: - The fallback chain

    @Test("The name the client sent wins, because it is the one thing it stated explicitly")
    func statedOperationNameWins() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: "query GetAccountSummary { accountSummary { balance } }",
            operationName: "GetAccountSummary"
        ))
        #expect(operation?.name == "GetAccountSummary")
        #expect(operation?.kind == .query)
        #expect(operation?.isInferred == false)
    }

    @Test("Without operationName the name is read out of the document")
    func fallsBackToDocumentName() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: "query GetAccountSummary { accountSummary { balance } }"
        ))
        #expect(operation?.name == "GetAccountSummary")
        #expect(operation?.isInferred == true)
    }

    @Test("An anonymous operation falls back to its first root field")
    func fallsBackToRootField() {
        // Nothing names this, so the field being selected is the only thing distinguishing it.
        let summary = GraphQLRequest.operation(inBody: Self.body(query: "query { accountSummary { balance } }"))
        #expect(summary?.name == "accountSummary")

        let inbox = GraphQLRequest.operation(inBody: Self.body(query: "query { inbox { messages } }"))
        #expect(inbox?.name == "inbox")
        #expect(summary?.name != inbox?.name, "two anonymous queries must still be distinguishable")
    }

    @Test("Shorthand syntax works, which is what an ad-hoc client sends")
    func shorthandSyntax() {
        let operation = GraphQLRequest.operation(inBody: Self.body(query: "{ accountSummary { balance } }"))
        #expect(operation?.name == "accountSummary")
        #expect(operation?.kind == .query)
    }

    // MARK: - Operation kinds

    @Test("Mutations and subscriptions are recognized as such")
    func recognizesKinds() {
        let mutation = GraphQLRequest.operation(inBody: Self.body(query: "mutation SendPayment { pay { id } }"))
        #expect(mutation?.kind == .mutation)
        #expect(mutation?.name == "SendPayment")

        let subscription = GraphQLRequest.operation(inBody: Self.body(query: "subscription OnTick { tick }"))
        #expect(subscription?.kind == .subscription)
    }

    @Test("An anonymous mutation still reports its kind")
    func anonymousMutationKeepsItsKind() {
        let operation = GraphQLRequest.operation(inBody: Self.body(query: "mutation { pay { id } }"))
        #expect(operation?.kind == .mutation)
        #expect(operation?.name == "pay")
    }

    // MARK: - Document shapes that trip naive parsers

    @Test("Variable definitions do not swallow the operation name")
    func variableDefinitions() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: "query GetUser($id: ID!, $withPosts: Boolean = false) { user(id: $id) { name } }"
        ))
        #expect(operation?.name == "GetUser")
    }

    @Test("An anonymous query with variables still resolves to its root field")
    func anonymousWithVariables() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: "query ($id: ID!) { user(id: $id) { name } }"
        ))
        #expect(operation?.name == "user")
    }

    @Test("Comments cannot fake an operation, even containing braces or keywords")
    func commentsAreIgnored() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: """
            # query Decoy { notReal }
            query RealOne {
              # { alsoNotReal }
              accountSummary { balance }
            }
            """
        ))
        #expect(operation?.name == "RealOne")
    }

    @Test("An alias resolves to the field, which is the stable half of the pair")
    func aliasResolvesToField() {
        // The alias is whatever the caller felt like typing; the field is what the schema calls it.
        let operation = GraphQLRequest.operation(inBody: Self.body(query: "{ summary: accountSummary { balance } }"))
        #expect(operation?.name == "accountSummary")
    }

    @Test("Leading whitespace and newlines are tolerated")
    func toleratesFormatting() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: "\n\n   query   GetThing   {\n  thing\n}\n"
        ))
        #expect(operation?.name == "GetThing")
    }

    /// This case could not fail, before the fragment fix or after it.
    ///
    /// It put the fragment *after* the query — which the scanner never reaches, because it stops at
    /// the first selection set — and passed `operationName: "GetUser"`, which takes the `stated`
    /// branch in `operation(inPayload:)` and returns without calling `parseDocument` at all. So the
    /// name it asserted came from the payload's own field, and the parser under test was never run.
    ///
    /// Both halves of the fixture are now the opposite: the fragment comes first, which is where real
    /// clients put it, and no `operationName` is sent, which is what forces the name to be read out
    /// of the document. Before the fix this resolved to `"name"` — the fragment's first field — so an
    /// endpoint declared for `GetUser` did not match and a well-formed request 404'd.
    @Test("A fragment ahead of the operation does not become the operation")
    func fragmentsDoNotWin() {
        let operation = GraphQLRequest.operation(inBody: Self.body(
            query: """
            fragment fields on User { name }
            query GetUser { user { ...fields } }
            """
        ))
        #expect(operation?.name == "GetUser")
        #expect(operation?.kind == .query)
        #expect(operation?.isInferred == true, "the name has to have come from the document")
    }

    /// The shapes a real client's fragment block actually takes, all ahead of the operation: several
    /// fragments in a row, nested selection sets that have to close more than once, a directive on
    /// the fragment itself, and an anonymous operation whose name then comes from its own root field
    /// rather than from anything in the fragments.
    @Test(
        "Fragment blocks of every shape are stepped over",
        arguments: [
            (
                """
                fragment a on User { id }
                fragment b on Inbox { count }
                query GetUser { user { ...a } }
                """,
                "GetUser"
            ),
            (
                """
                fragment deep on User { profile { address { city } } }
                query GetUser { user { ...deep } }
                """,
                "GetUser"
            ),
            (
                """
                fragment flagged on User @include(if: $withUser) { id }
                mutation SendPayment { pay { id } }
                """,
                "SendPayment"
            ),
            (
                """
                fragment fields on User { name }
                { accountSummary { balance } }
                """,
                "accountSummary"
            ),
        ]
    )
    func fragmentBlocksAreSkipped(query: String, expected: String) {
        #expect(GraphQLRequest.operation(inBody: Self.body(query: query))?.name == expected)
    }

    /// A fragment whose braces never close leaves nothing trustworthy behind it, so the scanner gives
    /// the answer it gives everything it cannot read: none. The request falls back to plain path
    /// routing instead of matching on a name guessed out of a broken document.
    @Test("An unterminated fragment degrades to no match rather than a wrong one")
    func unterminatedFragmentYieldsNothing() {
        #expect(GraphQLRequest.operation(inBody: Self.body(
            query: "fragment fields on User { name query GetUser { user { id } }"
        )) == nil)
    }

    // MARK: - Not GraphQL

    @Test("A body that is not GraphQL yields no operation, so plain routing still applies")
    func nonGraphQLBodies() {
        #expect(GraphQLRequest.operation(inBody: nil) == nil)
        #expect(GraphQLRequest.operation(inBody: "") == nil)
        #expect(GraphQLRequest.operation(inBody: "not json at all") == nil)
        #expect(GraphQLRequest.operation(inBody: #"{"user":{"name":"Ada"}}"#) == nil)
        #expect(GraphQLRequest.operation(inBody: "[1, 2, 3]") == nil)
    }

    @Test("A malformed document degrades to no match rather than a wrong one")
    func malformedDocument() {
        #expect(GraphQLRequest.operation(inBody: Self.body(query: "")) == nil)
        #expect(GraphQLRequest.operation(inBody: Self.body(query: "!!!")) == nil)
    }

    // MARK: - Batching

    @Test("A batched request reports every operation, and matches none of them")
    func batchedRequests() {
        let batch = """
        [
          { "operationName": "GetUser", "query": "query GetUser { user { id } }" },
          { "operationName": "GetInbox", "query": "query GetInbox { inbox { id } }" }
        ]
        """
        #expect(GraphQLRequest.operations(inBody: batch).map(\.name) == ["GetUser", "GetInbox"])
        #expect(GraphQLRequest.isBatched(body: batch))

        // A batch expects an array back, which no single mocked response can represent — answering
        // with one of them would be silently wrong.
        #expect(GraphQLRequest.operation(inBody: batch) == nil)
    }
}

@Suite("GraphQL endpoint matching")
struct GraphQLEndpointMatchingTests {

    static func endpoint(operation: String?, status: Int, name: String) -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: status, body: #"{"op":"\#(name)"}"#)
        return Endpoint(
            name: name,
            method: .post,
            path: "/graphql",
            scenarios: [scenario],
            activeScenarioID: scenario.id,
            graphqlOperation: operation
        )
    }

    static func request(_ operationName: String) -> IncomingRequest {
        IncomingRequest(
            method: .post,
            path: "/graphql",
            body: #"{"operationName":"\#(operationName)","query":"query \#(operationName) { x }"}"#
        )
    }

    @Test("Two operations on one path resolve to different mocks")
    func operationsAreDistinguished() {
        let endpoints = [
            Self.endpoint(operation: "GetAccountSummary", status: 200, name: "summary"),
            Self.endpoint(operation: "SendPayment", status: 201, name: "payment"),
        ]

        #expect(MockResolver.plan(request: Self.request("GetAccountSummary"), endpoints: endpoints, globalDelayMs: 0)
            .response.statusCode == 200)
        #expect(MockResolver.plan(request: Self.request("SendPayment"), endpoints: endpoints, globalDelayMs: 0)
            .response.statusCode == 201)
    }

    @Test("A named operation beats a catch-all on the same path")
    func namedOperationBeatsCatchAll() {
        let endpoints = [
            Self.endpoint(operation: nil, status: 500, name: "catch-all"),
            Self.endpoint(operation: "GetAccountSummary", status: 200, name: "summary"),
        ]
        let plan = MockResolver.plan(request: Self.request("GetAccountSummary"), endpoints: endpoints, globalDelayMs: 0)
        #expect(plan.response.statusCode == 200, "the more specific mock must win")
    }

    @Test("Declaration order does not decide the winner")
    func orderIndependent() {
        let reversed = [
            Self.endpoint(operation: "GetAccountSummary", status: 200, name: "summary"),
            Self.endpoint(operation: nil, status: 500, name: "catch-all"),
        ]
        let plan = MockResolver.plan(request: Self.request("GetAccountSummary"), endpoints: reversed, globalDelayMs: 0)
        #expect(plan.response.statusCode == 200)
    }

    @Test("A catch-all still answers an operation nothing names")
    func catchAllStillWorks() {
        let endpoints = [
            Self.endpoint(operation: nil, status: 500, name: "catch-all"),
            Self.endpoint(operation: "GetAccountSummary", status: 200, name: "summary"),
        ]
        let plan = MockResolver.plan(request: Self.request("SomethingElse"), endpoints: endpoints, globalDelayMs: 0)
        #expect(plan.response.statusCode == 500)
    }

    @Test("A mock for one operation never answers another")
    func namedMockDoesNotOverreach() {
        let endpoints = [Self.endpoint(operation: "GetAccountSummary", status: 200, name: "summary")]
        let plan = MockResolver.plan(request: Self.request("SendPayment"), endpoints: endpoints, globalDelayMs: 0)

        // No catch-all exists, so this is genuinely unconfigured — and must say so.
        #expect(plan.response.outcome == .unmatched)
    }

    @Test("A named mock ignores a request with no GraphQL body at all")
    func nonGraphQLRequestDoesNotMatchNamedMock() {
        let endpoints = [Self.endpoint(operation: "GetAccountSummary", status: 200, name: "summary")]
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .post, path: "/graphql", body: "not graphql"),
            endpoints: endpoints,
            globalDelayMs: 0
        )
        #expect(plan.response.outcome == .unmatched)
    }

    @Test("REST endpoints are unaffected — no body, no operation, no change")
    func restIsUnaffected() {
        let scenario = Scenario(name: "Default", statusCode: 204)
        let rest = Endpoint(
            name: "inbox",
            method: .get,
            path: "/inbox",
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
        let plan = MockResolver.plan(
            request: IncomingRequest(method: .get, path: "/inbox"),
            endpoints: [rest],
            globalDelayMs: 0
        )
        #expect(plan.response.statusCode == 204)
    }
}

@Suite("GraphQL journey steps")
struct GraphQLJourneyTests {

    static func step(_ operation: String, _ status: Int) -> JourneyStep {
        JourneyStep(
            name: operation,
            method: .post,
            path: "/graphql",
            outcome: .respond(JourneyResponse(statusCode: status)),
            graphqlOperation: operation
        )
    }

    static func request(_ operationName: String) -> IncomingRequest {
        IncomingRequest(
            method: .post,
            path: "/graphql",
            body: #"{"operationName":"\#(operationName)","query":"query \#(operationName) { x }"}"#
        )
    }

    @Test("A GraphQL flow scripts several calls that are otherwise identical")
    func scriptsAGraphQLFlow() {
        // Every step is POST /graphql; without the operation they would be indistinguishable and the
        // journey would serve them in blind order.
        let journey = Journey(
            name: "Retry after failure",
            steps: [
                Self.step("SignIn", 200),
                Self.step("GetAccountSummary", 500),
                Self.step("GetInbox", 200),
                Self.step("GetAccountSummary", 200),
            ]
        )

        var state = JourneyRunState(journeyID: journey.id)
        var observed: [Int] = []
        for name in ["SignIn", "GetAccountSummary", "GetInbox", "GetAccountSummary"] {
            let plan = MockResolver.plan(
                request: Self.request(name),
                endpoints: [],
                globalDelayMs: 0,
                journey: journey,
                journeyState: state
            )
            state = plan.journeyState ?? state
            observed.append(plan.response.statusCode)
        }

        #expect(observed == [200, 500, 200, 200])
    }

    @Test("An operation the journey does not script falls through rather than stealing a step")
    func unscriptedOperationFallsThrough() {
        let journey = Journey(name: "Partial", steps: [Self.step("GetAccountSummary", 500)])
        let plan = MockResolver.plan(
            request: Self.request("SomethingElse"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )
        #expect(plan.response.outcome == .unmatched)
    }

    @Test("A step naming no operation still matches any GraphQL call, as a catch-all")
    func stepWithoutOperationIsACatchAll() {
        let journey = Journey(
            name: "Any",
            steps: [
                JourneyStep(
                    name: "anything",
                    method: .post,
                    path: "/graphql",
                    outcome: .respond(JourneyResponse(statusCode: 418))
                )
            ]
        )
        let plan = MockResolver.plan(
            request: Self.request("Whatever"),
            endpoints: [],
            globalDelayMs: 0,
            journey: journey,
            journeyState: JourneyRunState(journeyID: journey.id)
        )
        #expect(plan.response.statusCode == 418)
    }
}

@Suite("GraphQL document compatibility")
struct GraphQLDocumentCompatibilityTests {

    @Test("An endpoint saved before GraphQL matching existed still decodes")
    func legacyEndpointDecodes() throws {
        let legacy = """
        {
          "id": "6B1D3A2E-0000-4000-8000-000000000002",
          "name": "Login",
          "method": "POST",
          "path": "/login",
          "scenarios": [],
          "delayMs": 0
        }
        """
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(legacy.utf8))
        #expect(endpoint.name == "Login")
        #expect(endpoint.graphqlOperation == nil)
    }

    @Test("A journey step saved before GraphQL matching existed still decodes")
    func legacyStepDecodes() throws {
        let legacy = """
        {
          "id": "6B1D3A2E-0000-4000-8000-000000000003",
          "name": "Login",
          "method": "POST",
          "path": "/login",
          "outcome": { "respond": { "_0": { "statusCode": 200, "headers": {}, "contentType": "application/json" } } },
          "delayMs": 0,
          "repeatCount": 1
        }
        """
        let step = try JSONDecoder().decode(JourneyStep.self, from: Data(legacy.utf8))
        #expect(step.name == "Login")
        #expect(step.graphqlOperation == nil)
    }
}
