import Foundation

/// One operation carried in a GraphQL request.
public struct GraphQLOperation: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case query
        case mutation
        case subscription
    }

    /// The handle used for matching: the client's `operationName` when it sent one, otherwise the
    /// name in the document, otherwise the first root field.
    public let name: String
    public let kind: Kind
    /// `true` when the name was inferred from the document rather than stated by the client. Useful
    /// for telling someone why a mock matched something they did not name.
    public let isInferred: Bool

    public init(name: String, kind: Kind, isInferred: Bool = false) {
        self.name = name
        self.kind = kind
        self.isInferred = isInferred
    }
}

/// Recovers which GraphQL operation a request is asking for.
///
/// GraphQL puts every operation behind one route — almost always `POST /graphql` — so method and
/// path cannot tell two calls apart. The discriminator has to come from the body.
///
/// `operationName` is the obvious candidate but it is *optional*, and plenty of clients omit it for
/// anonymous operations. So this falls back in the order a human would: the name the client sent,
/// then the name written in the document, then the first root field being selected. That last one is
/// what makes `{ accountSummary { balance } }` distinguishable from `{ inbox { messages } }` even
/// though neither is named.
///
/// This is deliberately a tolerant scanner, not a GraphQL parser. It needs to identify an operation
/// in real traffic, not validate a schema, and being lenient about anything it does not understand is
/// the right trade: a body it cannot read is simply "not GraphQL", which falls back to plain routing.
public enum GraphQLRequest {

    /// The operation a request is asking for, or `nil` when the body is not a single GraphQL request.
    ///
    /// Returns `nil` for a batched request too — see ``operations(inBody:)``. A batch asks for several
    /// operations and expects an array back, which no single mock can answer honestly.
    public static func operation(inBody body: String?) -> GraphQLOperation? {
        let found = operations(inBody: body)
        return found.count == 1 ? found[0] : nil
    }

    /// Every operation in the body. Empty when it is not GraphQL; more than one for a batched request.
    public static func operations(inBody body: String?) -> [GraphQLOperation] {
        guard let body, !body.isEmpty,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        if let batch = json as? [Any] {
            return batch.compactMap { ($0 as? [String: Any]).flatMap(operation(inPayload:)) }
        }
        guard let payload = json as? [String: Any] else { return [] }
        return operation(inPayload: payload).map { [$0] } ?? []
    }

    /// `true` when the body carries more than one operation. Such a request expects an array of
    /// results, which a single mocked response cannot represent — worth reporting rather than
    /// silently matching one of them.
    public static func isBatched(body: String?) -> Bool {
        operations(inBody: body).count > 1
    }

    private static func operation(inPayload payload: [String: Any]) -> GraphQLOperation? {
        let document = payload["query"] as? String
        let statedRaw = (payload["operationName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stated = (statedRaw?.isEmpty == false) ? statedRaw : nil

        // A payload with neither is not a GraphQL request, whatever else it contains.
        guard document != nil || stated != nil else { return nil }

        let parsed = document.flatMap(parseDocument)

        if let stated {
            return GraphQLOperation(name: stated, kind: parsed?.kind ?? .query, isInferred: false)
        }
        guard let parsed, let name = parsed.name else { return nil }
        return GraphQLOperation(name: name, kind: parsed.kind, isInferred: true)
    }

    // MARK: - Document scanning

    struct ParsedDocument {
        let name: String?
        let kind: GraphQLOperation.Kind
    }

    /// Reads the operation kind and a usable name out of a GraphQL document.
    ///
    /// Handles the three shapes real clients send: a named operation (`query GetX { … }`), an
    /// anonymous one (`query { … }`), and the shorthand (`{ … }`). For the latter two the name comes
    /// from the first root field, since that is the only thing distinguishing them.
    static func parseDocument(_ document: String) -> ParsedDocument? {
        var scanner = Scanner(stripping: document)

        var kind = GraphQLOperation.Kind.query
        if let keyword = scanner.peekIdentifier(), let parsed = GraphQLOperation.Kind(rawValue: keyword) {
            kind = parsed
            _ = scanner.takeIdentifier()

            // `query GetX(...)` — the identifier after the keyword is the operation's name.
            if let name = scanner.takeIdentifier() {
                return ParsedDocument(name: name, kind: kind)
            }
        }

        // Anonymous or shorthand: fall through to the first field being selected.
        guard scanner.advanceToSelectionSet() else { return ParsedDocument(name: nil, kind: kind) }
        return ParsedDocument(name: scanner.takeRootField(), kind: kind)
    }

    /// A cursor over a GraphQL document with comments and strings removed.
    struct Scanner {
        private let characters: [Character]
        private var index: Int = 0

        init(stripping document: String) {
            characters = Array(Self.stripComments(document))
        }

        /// Removes `#` comments, which may otherwise contain braces or the word `query`.
        static func stripComments(_ document: String) -> String {
            document
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let hash = line.firstIndex(of: "#") else { return line }
                    return line[line.startIndex..<hash]
                }
                .joined(separator: "\n")
        }

        private mutating func skipWhitespaceAndCommas() {
            while index < characters.count, characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
        }

        private static func isNameCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        mutating func peekIdentifier() -> String? {
            var lookahead = self
            return lookahead.takeIdentifier()
        }

        mutating func takeIdentifier() -> String? {
            skipWhitespaceAndCommas()
            guard index < characters.count, characters[index].isLetter || characters[index] == "_" else {
                return nil
            }
            var name = ""
            while index < characters.count, Self.isNameCharacter(characters[index]) {
                name.append(characters[index])
                index += 1
            }
            return name.isEmpty ? nil : name
        }

        /// Moves past variable definitions and directives to the opening brace of the selection set.
        mutating func advanceToSelectionSet() -> Bool {
            var depth = 0
            while index < characters.count {
                let character = characters[index]
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if character == "{", depth <= 0 {
                    index += 1
                    return true
                }
                index += 1
            }
            return false
        }

        /// The first field in the selection set, resolving `alias: field` to the field.
        ///
        /// The field is the stable half of that pair — an alias is whatever the caller felt like
        /// typing — so matching on it survives a client renaming its locals.
        mutating func takeRootField() -> String? {
            guard let first = takeIdentifier() else { return nil }
            skipWhitespaceAndCommas()
            guard index < characters.count, characters[index] == ":" else { return first }
            index += 1
            return takeIdentifier() ?? first
        }
    }
}
