import ArgumentParser
import Domain
import Foundation

/// Parsing of the small vocabularies that appear as flag values.
///
/// Domain enums are deliberately *not* extended to conform to `ExpressibleByArgument`: whether such a
/// conformance is retroactive depends on how the modules are packaged, so it compiles under one build
/// system and warns or fails under another. Parsing here instead keeps the CLI portable, and lets a
/// flag accept the spellings a person would actually type (`get`, `GET`, `json`, `application/json`)
/// while still reporting the valid set when they do not.
public enum ArgumentParsing {

    public static func method(_ value: String) throws -> HTTPMethod {
        guard let method = HTTPMethod(rawValue: value.uppercased()) else {
            throw CLIFailure.badArgument(
                "Unknown HTTP method \"\(value)\". Valid: \(HTTPMethod.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return method
    }

    public static func matchMode(_ value: String) throws -> JourneyMatchMode {
        try named(value, label: "match mode")
    }

    public static func completion(_ value: String) throws -> JourneyCompletion {
        try named(value, label: "completion behavior")
    }

    public static func unmatchedBehavior(_ value: String) throws -> JourneyUnmatchedBehavior {
        try named(value, label: "unmatched behavior")
    }

    public static func resetScope(_ value: String) throws -> ResetScope {
        try named(value, label: "reset scope")
    }

    public static func contentType(_ value: String) throws -> Scenario.ContentType {
        switch value.lowercased() {
        case "json", "application/json": .json
        case "text", "plain", "plaintext", "text/plain": .plainText
        default: throw CLIFailure.badArgument("Unknown content type \"\(value)\". Valid: json, text.")
        }
    }

    public static func uuid(_ value: String, flag: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw CLIFailure.badArgument("\(flag) must be a UUID, got \"\(value)\".")
        }
        return uuid
    }

    /// Matches a `CaseIterable` raw-value enum case-insensitively, also accepting kebab-case for
    /// camelCase cases (`strict-sequence` for `strictSequence`).
    private static func named<T: RawRepresentable & CaseIterable>(
        _ value: String,
        label: String
    ) throws -> T where T.RawValue == String {
        let key = value.lowercased().replacingOccurrences(of: "-", with: "")
        if let match = T.allCases.first(where: { $0.rawValue.lowercased() == key }) {
            return match
        }
        throw CLIFailure.badArgument(
            "Unknown \(label) \"\(value)\". Valid: \(T.allCases.map(\.rawValue).joined(separator: ", "))."
        )
    }
}

/// Selecting an endpoint. A route is the natural handle; id and name are there for scripts that
/// already have one.
public struct EndpointSelector: ParsableArguments, Sendable {
    @Argument(help: "HTTP method, e.g. GET.")
    public var method: String?

    @Argument(help: "Endpoint path, e.g. /account-summary.")
    public var path: String?

    @Option(name: .long, help: "Select by endpoint id instead of route.")
    public var id: String?

    @Option(name: .long, help: "Select by endpoint name instead of route.")
    public var name: String?

    public init() {}

    public func resolve() throws -> EndpointRef {
        if let id { return .id(try ArgumentParsing.uuid(id, flag: "--id")) }
        if let method, let path { return .route(try ArgumentParsing.method(method), path) }
        if let path { return EndpointRef(path: path) }
        if let name { return .name(name) }
        throw CLIFailure.badArgument("Specify an endpoint as <METHOD> <PATH>, or with --id or --name.")
    }
}

/// Selecting a journey by name (the usual case) or id.
public struct JourneySelector: ParsableArguments, Sendable {
    @Argument(help: "Journey name.")
    public var name: String?

    @Option(name: .long, help: "Select by journey id instead of name.")
    public var id: String?

    public init() {}

    public func resolve() throws -> JourneyRef {
        if let id { return .id(try ArgumentParsing.uuid(id, flag: "--id")) }
        if let name { return .name(name) }
        throw CLIFailure.badArgument("Specify a journey name, or --id.")
    }

    /// For `journey activate` with no argument, which clears the selection.
    public func resolveOptional() throws -> JourneyRef? {
        if id == nil, name == nil { return nil }
        return try resolve()
    }
}

/// Selecting a journey step: by position (what a human reads off a listing), name, or id.
public struct StepSelector: ParsableArguments, Sendable {
    @Option(name: .long, help: "Zero-based step position.")
    public var index: Int?

    @Option(name: .long, help: "Select by step name.")
    public var step: String?

    @Option(name: .long, help: "Select by step id.")
    public var stepID: String?

    public init() {}

    public func resolve() throws -> JourneyStepRef {
        if let stepID { return .id(try ArgumentParsing.uuid(stepID, flag: "--step-id")) }
        if let index { return .index(index) }
        if let step { return .name(step) }
        throw CLIFailure.badArgument("Specify a step with --index, --step, or --step-id.")
    }
}

/// Response fields shared by scenario and journey-step commands.
public struct ResponseOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "HTTP status code.")
    public var status: Int?

    @Option(name: .long, help: "Response body, inline.")
    public var body: String?

    @Option(name: .long, help: "Read the response body from a file (use - for stdin).")
    public var bodyFile: String?

    @Option(name: [.customLong("header"), .customShort("H")], help: "Response header as Name:Value. Repeatable.")
    public var headers: [String] = []

    @Option(name: .long, help: "Body content type: json or text.")
    public var contentType: String?

    public init() {}

    /// Resolves the body from whichever source was given. `--body-file -` reads stdin, which is how a
    /// large JSON payload gets in without shell quoting problems.
    public func resolveBody() throws -> String? {
        if let bodyFile {
            if bodyFile == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
            }
            do {
                return try String(contentsOfFile: bodyFile, encoding: .utf8)
            } catch {
                throw CLIFailure.fileUnreadable(path: bodyFile, underlying: error.localizedDescription)
            }
        }
        return body
    }

    public func resolveHeaders() throws -> [String: String]? {
        guard !headers.isEmpty else { return nil }
        var result: [String: String] = [:]
        for entry in headers {
            guard let separator = entry.firstIndex(of: ":") else {
                throw CLIFailure.badArgument("Header must be Name:Value, got \"\(entry)\".")
            }
            let name = String(entry[entry.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(entry[entry.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw CLIFailure.badArgument("Header name must not be empty in \"\(entry)\".")
            }
            result[name] = value
        }
        return result
    }

    public func resolveContentType() throws -> Scenario.ContentType? {
        try contentType.map(ArgumentParsing.contentType)
    }

    public func scenarioSpec(name: String? = nil) throws -> ScenarioSpec {
        ScenarioSpec(
            name: name,
            statusCode: status,
            headers: try resolveHeaders(),
            body: try resolveBody(),
            contentType: try resolveContentType()
        )
    }
}

/// How a journey step fails, when it fails.
public struct FailureOption: ParsableArguments, Sendable {
    @Option(name: .long, help: "Fail at the transport level instead of responding: drop or timeout.")
    public var fail: String?

    @Option(name: .long, help: "For --fail timeout, how long to hold the connection (ms).")
    public var holdMs: Int?

    public init() {}

    public func resolve() throws -> NetworkFailure? {
        guard let fail else {
            if holdMs != nil {
                throw CLIFailure.badArgument("--hold-ms only applies with --fail timeout.")
            }
            return nil
        }
        switch fail.lowercased() {
        case "drop", "connectiondrop", "connection-drop":
            if holdMs != nil {
                throw CLIFailure.badArgument("--hold-ms only applies with --fail timeout.")
            }
            return .connectionDrop
        case "timeout", "hang":
            return .timeout(holdMs: holdMs ?? NetworkFailure.defaultTimeoutHoldMs)
        default:
            throw CLIFailure.badArgument("--fail must be drop or timeout, got \"\(fail)\".")
        }
    }
}
