import Foundation
import Domain
import OpenAPIKit30

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
            return candidatesFromDocument(document, existingEndpoints: existingEndpoints)
        }.value
    }

    // MARK: - Swagger 2.0

    private static func parseSwagger2(
        data: Data,
        existingEndpoints: [Endpoint]
    ) throws -> [ImportCandidate] {
        let doc = try JSONDecoder().decode(SwaggerDocument.self, from: data)
        var candidates: [ImportCandidate] = []

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

                var (statusCode, exampleBody, responseDescription) = extractSwagger2Response(from: operation, doc: doc)
                let contentType: Scenario.ContentType = (operation.produces?.contains("application/json") ?? false) ? .json : .plainText

                // Fallback: auto-generate body from operation metadata when no schema/examples
                if exampleBody == nil && contentType == .json {
                    exampleBody = SchemaExampleGenerator.generateFallbackBody(
                        description: responseDescription,
                        parameters: operation.parameters
                    )
                }
                let name = suggestSwagger2Name(operation: operation, method: method, path: pathString)
                let groupTag = HARParser.suggestGroupTag(path: pathString)
                let bodySize = exampleBody?.utf8.count ?? 0

                let isDuplicate = existingEndpoints.contains { ep in
                    ep.method == method && ep.path == pathString
                }

                candidates.append(ImportCandidate(
                    id: UUID(),
                    isSelected: !isDuplicate,
                    method: method,
                    path: pathString,
                    suggestedName: name,
                    suggestedGroupTag: groupTag,
                    statusCode: statusCode,
                    responseHeaders: [:],
                    responseBody: bodySize > HARParser.bodySizeLimit ? nil : exampleBody,
                    responseContentType: contentType,
                    // An OpenAPI document describes REST routes; GraphQL operations do not appear in one.
                    graphqlOperation: nil,
                    bodySizeBytes: bodySize,
                    bodySizeExceedsLimit: bodySize > HARParser.bodySizeLimit,
                    isDuplicate: isDuplicate
                ))
            }
        }

        return candidates
    }

    private static func extractSwagger2Response(
        from operation: SwaggerOperation,
        doc: SwaggerDocument
    ) -> (statusCode: Int, body: String?, responseDescription: String?) {
        guard let responses = operation.responses else { return (200, nil, nil) }

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

        let statusCode = Int(bestKey ?? "200") ?? 200

        guard let response = responses[bestKey ?? "200"] else { return (statusCode, nil, nil) }

        // Check response examples
        if let examples = response.examples {
            if let jsonExample = examples["application/json"] {
                return (statusCode, jsonExample.toJSONString(), response.description)
            }
            if let first = examples.first {
                return (statusCode, first.value.toJSONString(), response.description)
            }
        }

        // Check schema example
        if let schemaExample = response.schema?.example {
            return (statusCode, schemaExample.toJSONString(), response.description)
        }

        // Generate from schema
        if let schema = response.schema {
            if let generated = SchemaExampleGenerator.generate(from: schema, definitions: doc.definitions) {
                if let jsonStr = SchemaExampleGenerator.toJSONString(generated) {
                    return (statusCode, jsonStr, response.description)
                }
            }
        }

        return (statusCode, nil, response.description)
    }

    private static func suggestSwagger2Name(
        operation: SwaggerOperation,
        method: HTTPMethod,
        path: String
    ) -> String {
        suggestName(operationId: operation.operationId, summary: operation.summary, method: method, path: path)
    }

    // MARK: - Private

    private static func candidatesFromDocument(
        _ document: OpenAPI.Document,
        existingEndpoints: [Endpoint]
    ) -> [ImportCandidate] {
        var candidates: [ImportCandidate] = []

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

                let (statusCode, exampleBody, contentType, headers) = extractBestResponse(
                    from: operation,
                    document: document
                )
                let name = suggestName(operation: operation, method: method, path: pathString)
                candidates.append(ImportCandidateBuilder.makeCandidate(
                    method: method,
                    path: pathString,
                    suggestedName: name,
                    suggestedGroupTag: HARParser.suggestGroupTag(path: pathString),
                    statusCode: statusCode,
                    responseHeaders: headers,
                    responseBody: exampleBody,
                    responseContentType: contentType,
                    existingEndpoints: existingEndpoints
                ))
            }
        }

        return candidates
    }

    /// Extract the best response: prefer 200/201, then first 2xx, then first response.
    /// When no schema or examples are available, auto-generates a placeholder body from operation metadata.
    private static func extractBestResponse(
        from operation: OpenAPI.Operation,
        document: OpenAPI.Document
    ) -> (statusCode: Int, body: String?, contentType: Scenario.ContentType, headers: [String: String]) {
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
            bestKey = responses.keys.first { key in
                switch key.value {
                case .status(code: let code):
                    return (200..<300).contains(code)
                case .range(let range):
                    return range == .success
                case .default:
                    return false
                }
            } ?? responses.keys.first
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
            if let resolved = try? document.components.lookup(ref) {
                response = resolved
            } else {
                return (statusCode, nil, .json, [:])
            }
        case .b(let resp):
            response = resp
        }

        // Extract example body from content
        var exampleBody: String?
        var contentType: Scenario.ContentType = .json

        let jsonKey = OpenAPI.ContentType.json
        if let jsonContent = response.content[jsonKey] {
            exampleBody = extractExample(from: jsonContent, document: document)
            contentType = .json
        } else if let firstContent = response.content.first {
            exampleBody = extractExample(from: firstContent.value, document: document)
            contentType = firstContent.key.rawValue.contains("json") ? .json : .plainText
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
        document: OpenAPI.Document
    ) -> String? {
        // 1. Check direct example
        if let example = content.example {
            return jsonString(from: example)
        }

        // 2. Check examples map
        if let examples = content.examples {
            for (_, exampleRef) in examples {
                switch exampleRef {
                case .a(let ref):
                    if let resolved = try? document.components.lookup(ref),
                       let value = resolved.value {
                        switch value {
                        case .a: continue
                        case .b(let anyCodable): return jsonString(from: anyCodable)
                        }
                    }
                case .b(let example):
                    if let value = example.value {
                        switch value {
                        case .a: continue
                        case .b(let anyCodable): return jsonString(from: anyCodable)
                        }
                    }
                }
            }
        }

        // 3. Generate from schema
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
                return SchemaExampleGenerator.toJSONString(generated)
            }
        }

        return nil
    }

    private static func jsonString(from anyCodable: AnyCodable) -> String? {
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

    private static func suggestName(operation: OpenAPI.Operation, method: HTTPMethod, path: String) -> String {
        suggestName(operationId: operation.operationId, summary: operation.summary, method: method, path: path)
    }

    /// Shared name suggestion: summary → operationId → path-based fallback.
    ///
    /// **Summary first**, which is the reverse of what this used to do. `operationId` is a machine
    /// identifier and `summary` is the sentence the spec's author wrote for a human to read — and the
    /// name here becomes an endpoint's label in the sidebar, which is about as human-facing as it
    /// gets. A spec that says `operationId: getAccountSummary`, `summary: Account summary` produced
    /// "GetAccountSummary": one run-together word, harder to read than the words beside it, and not
    /// the shape the HAR importer produces for the same endpoint ("Get Account-Summary").
    ///
    /// The `operationId` fallback now splits camelCase as well as `_` and `-`, since camelCase is how
    /// operation ids are overwhelmingly written and splitting on separators alone left them joined.
    private static func suggestName(operationId: String?, summary: String?, method: HTTPMethod, path: String) -> String {
        if let summary, !summary.isEmpty {
            return summary
        }
        if let operationId, !operationId.isEmpty {
            return humanized(operationId)
        }
        return ImportCandidateBuilder.suggestName(method: method, path: path)
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
