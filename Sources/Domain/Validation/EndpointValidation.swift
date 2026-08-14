import Foundation

public enum ValidationError: Error, Sendable, LocalizedError {
    case invalidPath(String)
    case invalidStatusCode(Int)
    case invalidPort(Int)
    case invalidHeaderName(String)
    case invalidHeaderValue(name: String)
    /// A field or a reference inside an imported document, with enough context to find it. The wrapped
    /// message is usually another `ValidationError`'s description — the reason is then not restated
    /// here — and otherwise a whole sentence written by ``ProjectValidator``, for the failures no
    /// per-field validator can express.
    case invalidDocument(context: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let reason): return "Invalid path: \(reason)"
        case .invalidStatusCode(let code):
            return "Invalid status code: \(code). Must be between 200 and 599 — "
                + "1xx is an interim status, not a response a mock can complete."
        case .invalidPort(let port): return "Invalid port: \(port). Must be between 1 and 65535."
        case .invalidHeaderName(let name):
            return "Invalid header name \"\(name)\". Names must be a non-empty RFC 9110 token."
        case .invalidHeaderValue(let name):
            return "Invalid value for header \"\(name)\". Values must not contain CR, LF, or NUL."
        case let .invalidDocument(context, reason):
            return "\(context): \(reason)"
        }
    }
}

public enum EndpointValidator {
    public static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw ValidationError.invalidPath("Path must start with '/': \(path)")
        }
        guard path == path.trimmingCharacters(in: .whitespaces) else {
            throw ValidationError.invalidPath("Path must not have leading or trailing whitespace: \(path)")
        }
        guard !path.contains("//") else {
            throw ValidationError.invalidPath("Path must not contain double slashes: \(path)")
        }
    }

    /// The range a mock can actually answer with.
    ///
    /// Not `100...599`, which is what this used to accept. A 1xx is an *interim* status: NIO's
    /// server pipeline treats an informational head as "more is coming" and does not advance its
    /// state machine, so the body that follows trips an assertion and takes a debug build down. There
    /// is also nothing to mock — a client never sees a 1xx as the answer to its request.
    public static let serveableStatusCodes = 200...599

    public static func validateStatusCode(_ code: Int) throws {
        guard serveableStatusCodes.contains(code) else {
            throw ValidationError.invalidStatusCode(code)
        }
    }

    public static func validatePort(_ port: Int) throws {
        guard (1...65535).contains(port) else {
            throw ValidationError.invalidPort(port)
        }
    }

    /// Rejects header names and values that would corrupt the response Mimic writes.
    ///
    /// A value containing CR or LF does not become part of that header — it ends it, and everything
    /// after the break is parsed by the client as *further headers*. A scenario header of
    /// `"a\r\nSet-Cookie: evil=1"` really does put a `Set-Cookie` on the wire. Vapor builds its own
    /// HTTP/1 pipeline and does not install NIO's `NIOHTTPResponseHeadersValidator`, so nothing below
    /// this catches it; the check has to live here, where the value is accepted.
    ///
    /// Names are held to the RFC 9110 `token` grammar for the same reason: a space or a colon in a
    /// name is equally capable of splitting the header block.
    public static func validateHeader(name: String, value: String) throws {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(isTokenScalar) else {
            throw ValidationError.invalidHeaderName(name)
        }
        guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0.value == 0 }) else {
            throw ValidationError.invalidHeaderValue(name: name)
        }
    }

    public static func validateHeaders(_ headers: [String: String]) throws {
        for (name, value) in headers {
            try validateHeader(name: name, value: value)
        }
    }

    /// `true` when the header is safe to write. The non-throwing form, for the serving path where the
    /// only sensible response to a bad header is to drop it rather than fail the whole request.
    public static func isValidHeader(name: String, value: String) -> Bool {
        (try? validateHeader(name: name, value: value)) != nil
    }

    /// RFC 9110 §5.6.2 `tchar`.
    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~": true
        default: false
        }
    }
}

/// Whole-document validation, applied where a project arrives as *data* rather than as an edit.
///
/// The per-field validators above guard the editing path — `endpointCreate`, `scenarioUpdate` and so
/// on all call them. An imported document reaches the store without passing through any of that, so
/// without this it is the one way to get a value into a project that the app would never have let you
/// type. That mattered: a scenario with a negative status code was accepted by `projectImport` and
/// then trapped the process when it was served, taking the whole app with it.
public enum ProjectValidator {

    /// Checks the fields an import can carry that the serving path later trusts, **and the references
    /// between them**.
    ///
    /// Deliberately whole-document and fail-fast: a partially-imported project is harder to reason
    /// about than a rejected one, and the caller gets a message naming the offending endpoint.
    ///
    /// The reference checks are the half this did not use to do, and they are the half import actually
    /// breaks on. Every editing command maintains those references as an invariant — `scenarioDelete`
    /// repoints `activeScenarioID` at the first surviving scenario, `journeyDelete` clears
    /// `activeJourneyID` — so a document that carries a dangling one did not come from this app, which
    /// is exactly the case an import is. Both failures are silent at serving time: `RequestMatcher`
    /// skips an endpoint whose `activeScenarioID` resolves to no scenario it owns — a `continue`
    /// before that endpoint can win — so the route 404s as though it were never configured; and
    /// ``MockProject/activeJourney`` reads a dangling `activeJourneyID` as `nil`, so the server runs
    /// with no overlay while the document says a journey is active.
    public static func validate(_ project: MockProject) throws {
        // A document from a *newer* build, checked first because nothing below can be trusted to mean
        // what it says once the schema has moved. Decoding does not stop one: `MockProject.init(from:)`
        // keeps whatever version the document declares, unknown keys are dropped in silence, and the
        // synthesised encoder writes the higher number back out — so a v4 document imported here
        // becomes a v3 project still claiming to be v4, having quietly lost whatever v4 added.
        //
        // The numbers moved once already: this read v3-over-v2 until `currentSchemaVersion` was
        // corrected to 3, which is the version the tree has carried since `v3_graphql_operation`
        // added `graphqlOperation` to the document. An illustration written in literals has to be
        // renumbered whenever the constant moves — `MockProject.currentSchemaVersion` is the value,
        // and this sentence is only ever describing the shape of the failure.
        //
        // The version is checked here and nowhere else in `Sources`, which covers the import path —
        // where a *foreign* document arrives. It does not cover a store written by a newer build, and
        // could not: `ProjectRecord.toDomain` rebuilds through `MockProject`'s memberwise initialiser,
        // which stamps the current version over whatever the stored column holds, so the version never
        // survives a load to be checked. Closing that is Persistence's to do, not this type's.
        guard project.schemaVersion <= MockProject.currentSchemaVersion else {
            throw ValidationError.invalidDocument(
                context: "project \"\(project.name)\"",
                reason: "schemaVersion \(project.schemaVersion) was written by a newer version of "
                    + "Mimic. This build understands up to \(MockProject.currentSchemaVersion)."
            )
        }

        try EndpointValidator.validatePort(project.serverConfiguration.port)

        for endpoint in project.endpoints {
            do {
                try EndpointValidator.validatePath(endpoint.path)
                for scenario in endpoint.scenarios {
                    try EndpointValidator.validateStatusCode(scenario.statusCode)
                    try EndpointValidator.validateHeaders(scenario.headers)
                }
            } catch let error as ValidationError {
                throw ValidationError.invalidDocument(
                    context: context(for: endpoint),
                    reason: error.errorDescription ?? "invalid"
                )
            }

            // Thrown outside the `do` above on purpose: `invalidDocument` is itself a `ValidationError`,
            // so raising it in there would be caught and wrapped in a second one, reporting the endpoint
            // twice in one sentence.
            if let activeScenarioID = endpoint.activeScenarioID,
               endpoint.scenarios.contains(where: { $0.id == activeScenarioID }) == false {
                throw ValidationError.invalidDocument(
                    context: context(for: endpoint),
                    reason: "activeScenarioID names a scenario this endpoint does not have, so the "
                        + "endpoint would answer nothing at all."
                )
            }
        }

        for journey in project.journeys {
            for step in journey.steps {
                do {
                    try EndpointValidator.validatePath(step.path)
                    if case let .respond(response) = step.outcome {
                        try EndpointValidator.validateStatusCode(response.statusCode)
                        try EndpointValidator.validateHeaders(response.headers)
                    }
                } catch let error as ValidationError {
                    throw ValidationError.invalidDocument(
                        context: "journey \"\(journey.name)\", step \"\(step.name)\"",
                        reason: error.errorDescription ?? "invalid"
                    )
                }
            }
        }

        // A step is *not* checked against the endpoints, and should not be: a `JourneyStep` carries no
        // endpoint id — it matches on method and path with the same wildcards an endpoint uses — and a
        // journey deliberately scripts routes the project has no endpoint for. That is what
        // `JourneyUnmatchedBehavior` is for. There is no reference here to dangle.

        if let activeJourneyID = project.activeJourneyID,
           project.journeys.contains(where: { $0.id == activeJourneyID }) == false {
            throw ValidationError.invalidDocument(
                context: "project \"\(project.name)\"",
                reason: "activeJourneyID names a journey this project does not contain, so the "
                    + "server would run with no journey at all."
            )
        }
    }

    /// Names an endpoint the way a reader would find it in the window: by name, then by the route.
    /// Shared so a field failure and a reference failure report the same endpoint the same way.
    private static func context(for endpoint: Endpoint) -> String {
        "endpoint \"\(endpoint.name)\" (\(endpoint.method.rawValue) \(endpoint.path))"
    }
}

// Legacy free functions removed to enforce cohesive EndpointValidator usage
