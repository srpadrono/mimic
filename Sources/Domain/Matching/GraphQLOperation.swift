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
    /// Returns `nil` for any top-level JSON array. Even a one-element batch expects an array back,
    /// which no single mock can answer honestly.
    public static func operation(inBody body: String?) -> GraphQLOperation? {
        guard let payload = json(inBody: body) as? [String: Any] else { return nil }
        return operation(inPayload: payload)
    }

    /// Every readable operation in the body. An array can yield zero or one operation and still be a batch.
    public static func operations(inBody body: String?) -> [GraphQLOperation] {
        guard let json = json(inBody: body) else { return [] }

        if let batch = json as? [Any] {
            return batch.compactMap { ($0 as? [String: Any]).flatMap(operation(inPayload:)) }
        }
        guard let payload = json as? [String: Any] else { return [] }
        return operation(inPayload: payload).map { [$0] } ?? []
    }

    /// `true` when the body is a top-level JSON array, regardless of how many operations it contains.
    public static func isBatched(body: String?) -> Bool {
        json(inBody: body) is [Any]
    }

    private static func json(inBody body: String?) -> Any? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
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

        // Fragment definitions come first in most documents a real client emits, and nothing below
        // consumes a keyword it does not recognise, so a leading `fragment` used to sit in the buffer
        // and derail everything after it: `Kind(rawValue: "fragment")` is `nil`, so the branch below
        // declined it *without* advancing; `advanceToSelectionSet` then stopped at the fragment's own
        // opening brace; and `takeRootField` named the document after the fragment's first field. A
        // document reading `fragment fields on User { name }` ahead of `query GetUser { … }` resolved
        // to the operation "name", so an endpoint declared for "GetUser" did not match it and a
        // perfectly well-formed request 404'd.
        while scanner.peekIdentifier() == "fragment" {
            // A fragment whose braces never close leaves nothing trustworthy behind it. `nil` is the
            // tolerant answer this scanner gives anything it cannot read: the request falls back to
            // plain path routing rather than matching on a name guessed out of a broken document.
            guard scanner.skipFragmentDefinition() else { return nil }
        }

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

    /// A cursor over a GraphQL document with `#` comments removed.
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

        /// Consumes one whole fragment definition — the `fragment` keyword, its name, its `on Type`
        /// condition, any directives and its selection set — leaving the cursor on whatever follows.
        mutating func skipFragmentDefinition() -> Bool {
            guard takeIdentifier() != nil else { return false }
            guard advanceToSelectionSet() else { return false }
            return skipToEndOfSelectionSet()
        }

        /// Moves past the `}` that closes the selection set whose `{` has already been consumed.
        ///
        /// Brace-counted rather than run to the next `}`, because a fragment's selections nest:
        /// `fragment f on User { profile { name } }` has to close twice before the operation begins.
        mutating func skipToEndOfSelectionSet() -> Bool {
            var depth = 1
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return true }
                }
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
