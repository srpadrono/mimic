import Foundation
import Domain
import OpenAPIKit30

private enum OpenAPIImportError: LocalizedError {
    case unresolvedResponse(String)

    var errorDescription: String? {
        switch self {
        case .unresolvedResponse(let reference):
            return "Cannot resolve OpenAPI response reference \(reference)."
        }
    }
}

/// Parses OpenAPI v3 and Swagger v2 specs into import candidates.
public enum OpenAPIParser {

    /// Parse OpenAPI v3 or Swagger v2 JSON data into import candidates.
    /// Auto-detects the spec version.
    public static func parse(
        data: Data,
        existingEndpoints: [Endpoint] = []
    ) async throws -> [ImportCandidate] {
        try await Task.detached {
            // Peek at the JSON to detect spec version
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let swagger = dict["swagger"] as? String, swagger.hasPrefix("2") {
                return try parseSwagger2(data: data, existingEndpoints: existingEndpoints)
            }
            // Default: try OpenAPI 3.x
            let document = try JSONDecoder().decode(OpenAPI.Document.self, from: data)
            return try candidatesFromDocument(
                document,
                documentBasePath: openAPI3BasePath(in: data),
                existingEndpoints: existingEndpoints
            )
        }.value
    }

    /// The prefix an OpenAPI 3 document's first `servers` entry declares, or `nil` when it declares
    /// none. ``ImportPath`` reduces it; this only has to hand over the string the document wrote.
    ///
    /// Decoded straight from the JSON rather than read off `OpenAPI.Document.servers`, for two
    /// reasons. The prefix then arrives as the same kind of thing in both formats — a raw string
    /// beside Swagger 2's `basePath` — so one function reduces both and they cannot diverge. And
    /// nothing here has to reach into `URLTemplate`, which is declared in `OpenAPIKitCore`; this
    /// module imports `OpenAPIKit30` and not that.
    ///
    /// Server variables are substituted with their declared defaults first, because that is what
    /// the spec says an unbound variable means: `https://{region}.example.com/{tier}` with
    /// `tier: { default: "v2" }` serves `/v2`.
    static func openAPI3BasePath(in data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(OpenAPIServersEnvelope.self, from: data),
              let first = envelope.servers?.first,
              var url = first.url
        else { return nil }
        for (name, variable) in first.variables ?? [:] {
            guard let value = variable.default else { continue }
            url = url.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return url
    }

    // MARK: - Swagger 2.0

    private static func parseSwagger2(
        data: Data,
        existingEndpoints: [Endpoint]
    ) throws -> [ImportCandidate] {
        let doc = try JSONDecoder().decode(SwaggerDocument.self, from: data)
        var candidates: [ImportCandidate] = []
        var ledger = ImportRouteLedger(existingEndpoints: existingEndpoints)

        guard let paths = doc.paths else { return [] }

        for (pathString, pathItem) in paths.sorted(by: { $0.key < $1.key }) {
            let operations: [(String, SwaggerOperation?)] = [
                ("GET", pathItem.get),
                ("POST", pathItem.post),
                ("PUT", pathItem.put),
                ("PATCH", pathItem.patch),
                ("DELETE", pathItem.delete),
                ("HEAD", pathItem.head),
                ("OPTIONS", pathItem.options),
            ]

            for (methodString, operation) in operations {
                guard let operation else { continue }
                guard let method = HTTPMethod(rawValue: methodString) else { continue }

                // Choose the response once. When `produces` is absent, its examples can identify
                // the content type; an example on a different status must not decide it.
                let selectedResponse = selectedSwagger2Response(from: operation)
                let contentType = swagger2ContentType(
                    operation: operation,
                    doc: doc,
                    response: selectedResponse?.response
                )
                var (statusCode, exampleBody, responseDescription) = extractSwagger2Response(
                    from: selectedResponse,
                    doc: doc,
                    preferring: contentType
                )

                // Fallback: auto-generate body from operation metadata when no schema/examples
                if exampleBody == nil && contentType == .json {
                    exampleBody = SchemaExampleGenerator.generateFallbackBody(
                        description: responseDescription,
                        parameters: operation.parameters
                    )
                }

                // Through the builder, like every other importer. Built by hand, this path skipped
                // `ImportHeaderPolicy` and carried its own duplicate rule — one that ignored the
                // GraphQL operation the shared rule compares — so "one chokepoint means a future
                // importer cannot forget" was true of the chokepoint and not of this caller.
                candidates.append(ImportCandidateBuilder.makeCandidate(
                    method: method,
                    path: pathString,
                    // Declared once at the top of the document and, until now, decoded and then read
                    // by nothing: a spec saying `basePath: /v2` imported `/pet/{petId}` for a server
                    // that answers `/v2/pet/42`.
                    documentBasePath: doc.basePath,
                    suggestedName: suggestedSwagger2Name(operation: operation),
                    statusCode: statusCode,
                    responseHeaders: [:],
                    responseBody: exampleBody,
                    responseContentType: contentType,
                    // An OpenAPI document describes REST routes; GraphQL operations do not appear in one.
                    graphqlOperation: nil,
                    ledger: &ledger
                ))
            }
        }

        return candidates
    }

    /// The content type an operation actually produces: its own `produces`, then the document's,
    /// preferring a declared representation with an example on the chosen response. When neither
    /// declared representation has an example, prefer JSON; with no declaration, infer from the
    /// chosen response's examples and otherwise default to JSON.
    ///
    /// Matched with the same rule the other importers use — a substring test, via
    /// `ImportCandidateBuilder.detectContentType`. The exact `contains("application/json")` this
    /// replaced missed `application/hal+json` and `application/json; charset=utf-8`, both of which
    /// are ordinary things for a real spec to declare.
    ///
    /// With no declaration, use a JSON example if present, otherwise a text example. A selected
    /// response with no supported example defaults to JSON so the metadata fallback can supply a
    /// body. Mimic has only JSON and plain-text scenario types. A declared non-JSON `produces`
    /// still maps to plain text for compatibility, but only text examples are copied; XML and
    /// other unrelated examples cannot be replayed faithfully under that label.
    static func swagger2ContentType(
        operation: SwaggerOperation,
        doc: SwaggerDocument,
        response: SwaggerResponse?
    ) -> Scenario.ContentType {
        // An operation's own list wins over the document's; an empty list declares nothing, so it
        // falls through to the document rather than deciding for it.
        let declared = operation.produces?.isEmpty == false ? operation.produces : doc.produces
        if let declared, !declared.isEmpty {
            let exampleTypes = response?.examples?.keys.compactMap(supportedSwaggerExampleType) ?? []
            // A JSON preference must not discard the selected response's sole text example when
            // both representations are declared. Keep JSON first only when it has an example too.
            if declared.contains(where: { supportedSwaggerExampleType($0) == .json }),
               exampleTypes.contains(.json) {
                return .json
            }
            if declared.contains(where: { supportedSwaggerExampleType($0) == .plainText }),
               exampleTypes.contains(.plainText) {
                return .plainText
            }
            return declared.contains { ImportCandidateBuilder.detectContentType($0) == .json }
                ? .json : .plainText
        }
        let exampleKeys = response?.examples?.keys.sorted() ?? []
        if exampleKeys.contains(where: { supportedSwaggerExampleType($0) == .json }) { return .json }
        if exampleKeys.contains(where: { supportedSwaggerExampleType($0) == .plainText }) {
            return .plainText
        }
        return .json
    }

    private static func selectedSwagger2Response(
        from operation: SwaggerOperation
    ) -> (statusCode: Int, response: SwaggerResponse)? {
        guard let responses = operation.responses else { return nil }

        // Prefer 200, then 201, then first 2xx, then first
        let preferredKeys = ["200", "201"]
        var bestKey: String?
        for key in preferredKeys {
            if responses[key] != nil {
                bestKey = key
                break
            }
        }
        if bestKey == nil {
            bestKey = responses.keys.sorted().first { key in
                if let code = Int(key), (200..<300).contains(code) { return true }
                return false
            } ?? responses.keys.sorted().first
        }

        guard let bestKey, let response = responses[bestKey] else { return nil }
        return (Int(bestKey) ?? 200, response)
    }

    private static func extractSwagger2Response(
        from selected: (statusCode: Int, response: SwaggerResponse)?,
        doc: SwaggerDocument,
        preferring contentType: Scenario.ContentType
    ) -> (statusCode: Int, body: String?, responseDescription: String?) {
        guard let (statusCode, response) = selected else { return (200, nil, nil) }

        // The examples map is keyed by MIME type, so the body handed back is the one for the content
        // type the candidate will actually declare. The keys used to be consulted only for an exact
        // `application/json` hit, so `produces: [text/plain]` beside a JSON example served the JSON
        // body under a text/plain label — two halves of one response chosen independently. An exact
        // key wins first, so a map holding both `application/json` and `application/hal+json` under
        // `produces: [application/json]` serves the body actually named; then the same content-type
        // rule as `produces` itself. An unrelated example is not a fallback: importing a JSON body
        // under `text/plain` would make the mock answer a response the spec never declared.
        if let examples = response.examples, !examples.isEmpty {
            let keys = examples.keys.sorted()
            if let key = keys.first(where: { $0 == contentType.rawValue })
                ?? keys.first(where: { supportedSwaggerExampleType($0) == contentType }),
               let example = examples[key],
               let body = swaggerExampleBody(example, contentType: contentType) {
                return (statusCode, body, response.description)
            }
        }

        // Check schema example
        if let schemaExample = response.schema?.example {
            let body = swaggerExampleBody(schemaExample, contentType: contentType)
            return (statusCode, body, response.description)
        }

        // Generate from schema
        if let schema = response.schema {
            if let generated = SchemaExampleGenerator.generate(from: schema, definitions: doc.definitions) {
                if contentType == .plainText, let text = generated as? String {
                    return (statusCode, text, response.description)
                }
                if let body = SchemaExampleGenerator.toJSONString(generated) {
                    return (statusCode, body, response.description)
                }
            }
        }

        return (statusCode, nil, response.description)
    }

    private static func swaggerExampleBody(
        _ example: AnyCodableValue,
        contentType: Scenario.ContentType
    ) -> String? {
        if contentType == .plainText, case .string(let text) = example {
            return text
        }
        return example.toJSONString()
    }

    private static func supportedSwaggerExampleType(_ mimeType: String) -> Scenario.ContentType? {
        if ImportCandidateBuilder.detectContentType(mimeType) == .json { return .json }
        let lower = mimeType.lowercased().trimmingCharacters(in: .whitespaces)
        // Text formats share the one plain-text scenario type. XML is excluded even as `text/xml`:
        // replaying XML under `text/plain` would advertise the wrong representation.
        if lower.hasPrefix("text/"), !lower.contains("xml") { return .plainText }
        return nil
    }

    private static func suggestedSwagger2Name(operation: SwaggerOperation) -> String? {
        suggestedName(operationId: operation.operationId, summary: operation.summary)
    }

    // MARK: - Private

    private static func candidatesFromDocument(
        _ document: OpenAPI.Document,
        documentBasePath: String?,
        existingEndpoints: [Endpoint]
    ) throws -> [ImportCandidate] {
        var candidates: [ImportCandidate] = []
        var ledger = ImportRouteLedger(existingEndpoints: existingEndpoints)

        // Sorted, like the Swagger 2 path below. `document.paths` is a dictionary, so iterating it
        // raw put the review list in whatever order the hash gave — the same file could list its
        // endpoints differently on two imports, and neither order matched the spec. A list you scan
        // to decide what to keep has to hold still.
        for (path, pathItemEither) in document.paths.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // pathItemEither is Either<JSONReference<PathItem>, PathItem>
            // We only handle inline path items (.b case)
            let pathItem: OpenAPI.PathItem
            switch pathItemEither {
            case .a:
                // Referenced path item — skip (would need resolution)
                continue
            case .b(let item):
                pathItem = item
            }

            let pathString = path.rawValue

            let operations: [(OpenAPI.HttpMethod, OpenAPI.Operation?)] = [
                (.get, pathItem.get),
                (.post, pathItem.post),
                (.put, pathItem.put),
                (.patch, pathItem.patch),
                (.delete, pathItem.delete),
                (.head, pathItem.head),
                (.options, pathItem.options),
            ]

            for (httpMethod, operation) in operations {
                guard let operation else { continue }
                guard let method = domainMethod(from: httpMethod) else { continue }

                let (statusCode, exampleBody, contentType, headers) = try extractBestResponse(
                    from: operation,
                    document: document
                )
                let name = suggestedName(operation: operation)
                candidates.append(ImportCandidateBuilder.makeCandidate(
                    method: method,
                    path: pathString,
                    documentBasePath: documentBasePath,
                    suggestedName: name,
                    // The group tag used to be passed in from here as
                    // `HARParser.suggestGroupTag(path: pathString)`, which forwards to the very
                    // function the builder falls back to — so it was a no-op for a literal route and
                    // a divergence for a parameterised one, where only the builder's copy now knows
                    // that a wildcard segment does not name a resource. One caller fewer, and the
                    // two importers group identically by construction.
                    statusCode: statusCode,
                    responseHeaders: headers,
                    responseBody: exampleBody,
                    responseContentType: contentType,
                    ledger: &ledger
                ))
            }
        }

        return candidates
    }

    /// Extract the best response: prefer 200/201, then the lowest 2xx, then the lowest key.
    /// When no schema or examples are available, auto-generates a placeholder body from operation metadata.
    private static func extractBestResponse(
        from operation: OpenAPI.Operation,
        document: OpenAPI.Document
    ) throws -> (statusCode: Int, body: String?, contentType: Scenario.ContentType, headers: [String: String]) {
        let responses = operation.responses

        // Find best response key
        let preferred: [OpenAPI.Response.StatusCode] = [.status(code: 200), .status(code: 201)]
        var bestKey: OpenAPI.Response.StatusCode?
        for key in preferred {
            if responses[key] != nil {
                bestKey = key
                break
            }
        }
        if bestKey == nil {
            let sortedKeys = responses.keys.sorted { $0.rawValue < $1.rawValue }
            bestKey = sortedKeys.first { key in
                switch key.value {
                case .status(code: let code):
                    return (200..<300).contains(code)
                case .range(let range):
                    return range == .success
                case .default:
                    return false
                }
            } ?? sortedKeys.first
        }

        guard let statusKey = bestKey else {
            return (200, nil, .json, [:])
        }

        let statusCode: Int = {
            switch statusKey.value {
            case .status(code: let code): return code
            case .range(let range):
                switch range {
                case .information: return 100
                case .success: return 200
                case .redirect: return 300
                case .clientError: return 400
                case .serverError: return 500
                }
            case .default: return 200
            }
        }()

        guard let responseEither = responses[statusKey] else {
            return (statusCode, nil, .json, [:])
        }

        // Resolve the response (Either<JSONReference<Response>, Response>)
        let response: OpenAPI.Response
        switch responseEither {
        case .a(let ref):
            guard let resolved = try? document.components.lookup(ref) else {
                throw OpenAPIImportError.unresolvedResponse(ref.absoluteString)
            }
            response = resolved
        case .b(let resp):
            response = resp
        }

        // Extract example body from content
        var exampleBody: String?
        var contentType: Scenario.ContentType = .json

        let sortedContentKeys = response.content.keys.sorted { $0.rawValue < $1.rawValue }
        if let selectedKey = sortedContentKeys.first(where: { $0 == .json })
            ?? sortedContentKeys.first(where: {
                ImportCandidateBuilder.detectContentType($0.rawValue) == .json
            })
            ?? sortedContentKeys.first,
           let selectedContent = response.content[selectedKey] {
            contentType = ImportCandidateBuilder.detectContentType(selectedKey.rawValue)
            exampleBody = extractExample(
                from: selectedContent,
                document: document,
                contentType: contentType
            )
        }

        // Fallback: auto-generate body from operation metadata when no content/schema
        if exampleBody == nil && contentType == .json {
            // Resolve parameters (inline only)
            let resolvedParams: [OpenAPI.Parameter] = operation.parameters.compactMap { paramEither in
                switch paramEither {
                case .a: return nil
                case .b(let param): return param
                }
            }
            exampleBody = SchemaExampleGenerator.generateFallbackBody(
                description: response.description,
                parameters: resolvedParams
            )
        }

        return (statusCode, exampleBody, contentType, [:])
    }

    private static func extractExample(
        from content: OpenAPI.Content,
        document: OpenAPI.Document,
        contentType: Scenario.ContentType
    ) -> String? {
        // OpenAPIKit also populates `example` from the first inline member of `examples`.
        // Inspect the named map first so its selection is stable across decodes.
        if let examples = content.examples {
            for key in examples.keys.sorted() {
                guard let exampleRef = examples[key] else { continue }
                switch exampleRef {
                case .a(let ref):
                    if let resolved = try? document.components.lookup(ref),
                       let value = resolved.value {
                        switch value {
                        case .a: continue
                        case .b(let anyCodable): return jsonString(from: anyCodable, contentType: contentType)
                        }
                    }
                case .b(let example):
                    if let value = example.value {
                        switch value {
                        case .a: continue
                        case .b(let anyCodable): return jsonString(from: anyCodable, contentType: contentType)
                        }
                    }
                }
            }
        }

        // A single direct example, when there is no usable named one.
        if let example = content.example {
            return jsonString(from: example, contentType: contentType)
        }

        // Generate from schema when no usable example exists.
        if let schemaEither = content.schema {
            let resolvedSchema: JSONSchema?
            switch schemaEither {
            case .a(let ref):
                resolvedSchema = try? document.components.lookup(ref)
            case .b(let schema):
                resolvedSchema = schema
            }
            if let schema = resolvedSchema,
               let generated = SchemaExampleGenerator.generate(from: schema, in: document) {
                if contentType == .plainText, let text = generated as? String {
                    return text
                }
                return SchemaExampleGenerator.toJSONString(generated)
            }
        }

        return nil
    }

    private static func jsonString(from anyCodable: AnyCodable, contentType: Scenario.ContentType) -> String? {
        if contentType == .plainText, let text = anyCodable.value as? String {
            return text
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(anyCodable) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func domainMethod(from method: OpenAPI.HttpMethod) -> HTTPMethod? {
        switch method {
        case .get: return .get
        case .post: return .post
        case .put: return .put
        case .patch: return .patch
        case .delete: return .delete
        case .head: return .head
        case .options: return .options
        case .trace: return nil
        }
    }

    private static func suggestedName(operation: OpenAPI.Operation) -> String? {
        suggestedName(operationId: operation.operationId, summary: operation.summary)
    }

    /// Shared name suggestion: summary → operationId → **nothing**, meaning the builder decides.
    ///
    /// **Summary first**, which is the reverse of what this used to do. `operationId` is a machine
    /// identifier and `summary` is the sentence the spec's author wrote for a human to read — and the
    /// name here becomes an endpoint's label in the sidebar, which is about as human-facing as it
    /// gets. A spec that says `operationId: getAccountSummary`, `summary: Account summary` produced
    /// "GetAccountSummary": one run-together word, harder to read than the words beside it, and not
    /// the shape the HAR importer produces for the same endpoint ("Get Account-Summary").
    ///
    /// The `operationId` fallback splits camelCase as well as `_` and `-`, since camelCase is how
    /// operation ids are overwhelmingly written and splitting on separators alone left them joined.
    ///
    /// The last step returns `nil` rather than calling `ImportCandidateBuilder.suggestName` itself,
    /// which is what it used to do. That call reached the right function with the wrong argument —
    /// the path as the *document* spelled it — so a spec offering neither a summary nor an
    /// `operationId` for `/pet/{petId}` was labelled "Get {Petid}" in the sidebar. Declining to name
    /// it hands the decision back to the one place that holds the rewritten route.
    private static func suggestedName(operationId: String?, summary: String?) -> String? {
        if let summary, !summary.isEmpty {
            return summary
        }
        if let operationId, !operationId.isEmpty {
            return humanized(operationId)
        }
        return nil
    }

    /// Turns `getAccountSummary`, `get_account_summary` or `get-account-summary` into
    /// "Get Account Summary".
    ///
    /// Title Case, matching `ImportCandidateBuilder.suggestName` — the fallback both importers share,
    /// which produces "Get Account-Summary" for the same endpoint out of a HAR. Sentence case would
    /// read better beside the rest of the window, but it is the *convention for generated endpoint
    /// names* that has to be one thing, and changing it belongs with changing it in both importers
    /// rather than leaving them disagreeing in a new direction.
    ///
    /// A `summary` from the spec is not passed through here: that is the author's own prose and is
    /// used exactly as written.
    static func humanized(_ identifier: String) -> String {
        var spaced = ""
        for character in identifier {
            if character == "_" || character == "-" {
                spaced.append(" ")
            } else if character.isUppercase, spaced.isEmpty == false, spaced.last != " " {
                spaced.append(" ")
                spaced.append(character)
            } else {
                spaced.append(character)
            }
        }
        return spaced
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Just enough of an OpenAPI 3 document to read its `servers` array, decoded alongside the full
/// parse rather than through it — see ``OpenAPIParser/openAPI3BasePath(in:)``.
///
/// Every field is optional, and the decode above is `try?`ed, so this can never be what fails an
/// import: a document with no `servers`, or one whose entries carry keys this does not model,
/// simply imports with no prefix — exactly as every document did before there was one.
///
/// It is not a validator, and must not be read as one. `OpenAPI.Document` has already decoded the
/// same bytes by the time this runs, and it is the thing that rejects a genuinely malformed
/// `servers` — `OpenAPI.Server` requires `url`, so an entry without one throws out of the full
/// decode before this is ever reached.
private struct OpenAPIServersEnvelope: Decodable {
    struct Server: Decodable {
        struct Variable: Decodable {
            let `default`: String?
        }

        let url: String?
        let variables: [String: Variable]?
    }

    let servers: [Server]?
}
