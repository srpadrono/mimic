import Foundation

public enum ValidationError: Error, Sendable, LocalizedError {
    case invalidPath(String)
    case invalidStatusCode(Int)
    case invalidPort(Int)
    case invalidHeaderName(String)
    case invalidHeaderValue(name: String)
    /// A field inside an imported document, with enough context to find it. The wrapped message is
    /// another `ValidationError`'s description, so the reason is not restated here.
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

    /// Checks every field an import can carry that the serving path later trusts.
    ///
    /// Deliberately whole-document and fail-fast: a partially-imported project is harder to reason
    /// about than a rejected one, and the caller gets a message naming the offending endpoint.
    public static func validate(_ project: MockProject) throws {
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
                    context: "endpoint \"\(endpoint.name)\" (\(endpoint.method.rawValue) \(endpoint.path))",
                    reason: error.errorDescription ?? "invalid"
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
    }
}

// Legacy free functions removed to enforce cohesive EndpointValidator usage
