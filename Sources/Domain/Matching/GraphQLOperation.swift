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

        let parsed = document.flatMap { parseDocument($0, operationName: stated) }

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
    static func parseDocument(_ document: String, operationName: String? = nil) -> ParsedDocument? {
        var scanner = Scanner(document)

        while scanner.skipDescriptions() {
            if scanner.peekIdentifier() == "fragment" {
                guard scanner.skipFragmentDefinition() else { return nil }
                continue
            }

            var kind = GraphQLOperation.Kind.query
            var name: String?
            if let keyword = scanner.takeIdentifier() {
                guard let parsed = GraphQLOperation.Kind(rawValue: keyword) else { return nil }
                kind = parsed
                name = scanner.takeIdentifier()
            } else if !scanner.isAtSelectionSet {
                return nil
            }

            if let name, operationName == nil || name == operationName {
                return ParsedDocument(name: name, kind: kind)
            }

            guard scanner.advanceToSelectionSet() else { return nil }
            if operationName == nil {
                return ParsedDocument(name: scanner.takeRootField(), kind: kind)
            }

            // A client can select a later definition. Its kind belongs to that operation,
            // not to whichever query or mutation happened to appear first in the document.
            guard scanner.skipToEndOfSelectionSet() else { return nil }
        }
        return nil
    }

    /// A single forward scan over UTF-8. GraphQL names and delimiters are ASCII; string contents
    /// remain opaque, so scanning does not expand a large captured body into a Character array.
    struct Scanner {
        private let bytes: [UInt8]
        private var index: Int = 0

        init(_ document: String) {
            bytes = Array(document.utf8)
        }

        var isAtSelectionSet: Bool {
            index < bytes.count && bytes[index] == UInt8(ascii: "{")
        }

        private mutating func skipIgnored() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"),
                     UInt8(ascii: "\n"), UInt8(ascii: ","):
                    index += 1
                case UInt8(ascii: "#"):
                    while index < bytes.count,
                          bytes[index] != UInt8(ascii: "\n"), bytes[index] != UInt8(ascii: "\r") {
                        index += 1
                    }
                case 0xEF where index + 2 < bytes.count
                    && bytes[index + 1] == 0xBB && bytes[index + 2] == 0xBF:
                    index += 3 // UTF-8 byte order mark, allowed between GraphQL tokens.
                default:
                    return
                }
            }
        }

        private static func isNameStart(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: "_")
        }

        mutating func peekIdentifier() -> String? {
            var lookahead = self
            return lookahead.takeIdentifier()
        }

        mutating func takeIdentifier() -> String? {
            skipIgnored()
            guard index < bytes.count, Self.isNameStart(bytes[index]) else { return nil }
            let start = index
            while index < bytes.count,
                  Self.isNameStart(bytes[index]) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        /// Descriptions may precede executable definitions. Their text is not part of the operation.
        mutating func skipDescriptions() -> Bool {
            skipIgnored()
            while index < bytes.count, bytes[index] == UInt8(ascii: "\"") {
                guard skipString() else { return false }
                skipIgnored()
            }
            return index < bytes.count
        }

        private func isTripleQuote(at offset: Int) -> Bool {
            offset + 2 < bytes.count
                && bytes[offset] == UInt8(ascii: "\"")
                && bytes[offset + 1] == UInt8(ascii: "\"")
                && bytes[offset + 2] == UInt8(ascii: "\"")
        }

        /// Consumes a quoted or block string without interpreting its braces, comments, or escapes
        /// as document structure. An unfinished string cannot yield a trustworthy operation.
        private mutating func skipString() -> Bool {
            let isBlock = isTripleQuote(at: index)
            index += isBlock ? 3 : 1
            while index < bytes.count {
                if isBlock {
                    if bytes[index] == UInt8(ascii: "\\"), isTripleQuote(at: index + 1) {
                        index += 4
                    } else if isTripleQuote(at: index) {
                        index += 3
                        return true
                    } else {
                        index += 1
                    }
                } else {
                    switch bytes[index] {
                    case UInt8(ascii: "\""):
                        index += 1
                        return true
                    case UInt8(ascii: "\\"):
                        guard index + 1 < bytes.count else { return false }
                        index += 2
                    case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                        return false
                    default:
                        index += 1
                    }
                }
            }
            return false
        }

        /// Moves past variable definitions and directives to the opening brace of the selection set.
        mutating func advanceToSelectionSet() -> Bool {
            var depth = 0
            while index < bytes.count {
                skipIgnored()
                guard index < bytes.count else { return false }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    guard skipString() else { return false }
                    continue
                }
                if byte == UInt8(ascii: "(") { depth += 1 }
                if byte == UInt8(ascii: ")") {
                    guard depth > 0 else { return false }
                    depth -= 1
                }
                if byte == UInt8(ascii: "{"), depth == 0 {
                    index += 1
                    return true
                }
                index += 1
            }
            return false
        }

        /// Consumes a fragment's header, directives, and complete nested selection set.
        mutating func skipFragmentDefinition() -> Bool {
            guard takeIdentifier() != nil else { return false }
            guard advanceToSelectionSet() else { return false }
            return skipToEndOfSelectionSet()
        }

        /// Moves past the closing brace of a selection set whose opening brace was consumed.
        mutating func skipToEndOfSelectionSet() -> Bool {
            var depth = 1
            while index < bytes.count {
                skipIgnored()
                guard index < bytes.count else { return false }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    guard skipString() else { return false }
                    continue
                }
                index += 1
                if byte == UInt8(ascii: "{") { depth += 1 }
                if byte == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 { return true }
                }
            }
            return false
        }

        /// The first field in the selection set, resolving an alias to its underlying field.
        mutating func takeRootField() -> String? {
            guard let first = takeIdentifier() else { return nil }
            skipIgnored()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return first }
            index += 1
            return takeIdentifier() ?? first
        }
    }
}
