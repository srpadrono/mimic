import Foundation

/// Re-indents and classifies JSON for display without reparsing values or reordering keys.
/// Only JSON whitespace outside strings is rewritten. Truncated captures remain displayable.
public nonisolated enum JSONFormatter {
    public enum TokenKind: Equatable {
        case key
        case string
        case number
        case literal
        case punctuation
        case plain
    }

    public struct Token: Equatable {
        public let text: String
        public let kind: TokenKind

        public init(text: String, kind: TokenKind) {
            self.text = text
            self.kind = kind
        }
    }

    /// Callers display larger bodies verbatim to bound attributed-text rendering work.
    public static let formattingLimit = 20 * 1024

    /// Indentation can expand quadratically with nesting depth, even for small inputs.
    static let maxFormattedBytes = 256 * 1024

    /// Whether the body starts with an object or array after optional JSON whitespace.
    public static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.utf8.first(where: { !isJSONWhitespace($0) }) else { return false }
        return first == 0x7B || first == 0x5B
    }

    /// Returns nil for non-JSON-shaped bodies or when indentation exceeds the output budget.
    /// Display callers preserve existing line breaks; an explicit editor action passes reflow.
    public static func prettyPrinted(_ text: String, reflow: Bool = false) -> String? {
        guard looksLikeJSON(text) else { return nil }
        guard reflow || !text.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(min(text.utf8.count, maxFormattedBytes))

        // JSON delimiters are ASCII bytes. A Swift Character can combine a quote with a following
        // combining mark, so grapheme-based scanning can mistake string content for structure.
        let bytes = Array(text.utf8)
        var depth = 0
        var index = 0

        func append(_ byte: UInt8) -> Bool {
            guard output.count < maxFormattedBytes else { return false }
            output.append(byte)
            return true
        }

        func append(_ fragment: ArraySlice<UInt8>) -> Bool {
            guard fragment.count <= maxFormattedBytes - output.count else { return false }
            output.append(contentsOf: fragment)
            return true
        }

        func appendNewline(indent: Int) -> Bool {
            let indent = max(0, indent)
            let remaining = maxFormattedBytes - output.count
            // Check before multiplying or constructing indentation.
            guard remaining > 0, indent <= (remaining - 1) / 2 else { return false }
            output.append(0x0A)
            output.append(contentsOf: repeatElement(UInt8(0x20), count: 2 * indent))
            return true
        }

        func nextNonWhitespace(from start: Int) -> Int {
            var probe = start
            while probe < bytes.count, isJSONWhitespace(bytes[probe]) { probe += 1 }
            return probe
        }

        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x22 {
                let next = endOfString(bytes, from: index)
                guard append(bytes[index..<next]) else { return nil }
                index = next
                continue
            }

            switch byte {
            case 0x7B, 0x5B: // { [
                guard append(byte) else { return nil }
                // Keep empty containers on one line.
                let closing: UInt8 = byte == 0x7B ? 0x7D : 0x5D
                let probe = nextNonWhitespace(from: index + 1)
                if probe < bytes.count, bytes[probe] == closing {
                    guard append(closing) else { return nil }
                    index = probe + 1
                    continue
                }
                depth += 1
                guard appendNewline(indent: depth) else { return nil }

            case 0x7D, 0x5D: // } ]
                depth -= 1
                guard appendNewline(indent: depth), append(byte) else { return nil }

            case 0x2C: // ,
                guard append(byte), appendNewline(indent: depth) else { return nil }

            case 0x3A: // :
                guard append(byte), append(0x20) else { return nil }

            default:
                guard !isJSONWhitespace(byte) else { break }
                guard append(byte) else { return nil }
            }

            index += 1
        }

        return String(decoding: output, as: UTF8.self)
    }

    /// Splits JSON-shaped text into colored runs. Other text is one plain token.
    /// Token text always reassembles into the original UTF-8 bytes.
    public static func tokenize(_ text: String) -> [Token] {
        guard looksLikeJSON(text) else { return [Token(text: text, kind: .plain)] }

        var tokens: [Token] = []
        let bytes = Array(text.utf8)
        var index = 0

        while index < bytes.count {
            let start = index
            let byte = bytes[index]

            if byte == 0x22 {
                let next = endOfString(bytes, from: index)
                // A quoted string is a key when a colon follows it.
                var probe = next
                while probe < bytes.count, isJSONWhitespace(bytes[probe]) { probe += 1 }
                let isKey = probe < bytes.count && bytes[probe] == 0x3A
                tokens.append(Token(
                    text: String(decoding: bytes[start..<next], as: UTF8.self),
                    kind: isKey ? .key : .string
                ))
                index = next
                continue
            }

            if isPunctuation(byte) {
                tokens.append(Token(text: String(decoding: [byte], as: UTF8.self), kind: .punctuation))
                index += 1
                continue
            }

            if isJSONWhitespace(byte) {
                repeat { index += 1 } while index < bytes.count && isJSONWhitespace(bytes[index])
                tokens.append(Token(text: String(decoding: bytes[start..<index], as: UTF8.self), kind: .plain))
                continue
            }

            repeat { index += 1 } while index < bytes.count
                && bytes[index] != 0x22 && !isPunctuation(bytes[index]) && !isJSONWhitespace(bytes[index])
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            tokens.append(Token(text: word, kind: kindOfBareWord(word)))
        }

        return tokens
    }

    // MARK: - Scanning

    /// Returns the index after the closing quote, or the end of a truncated string.
    private static func endOfString(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            if isEscaped {
                isEscaped = false
            } else if byte == 0x5C {
                isEscaped = true
            } else if byte == 0x22 {
                break
            }
        }

        return index
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isPunctuation(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C: true
        default: false
        }
    }

    private static func kindOfBareWord(_ word: String) -> TokenKind {
        switch word {
        case "true", "false", "null": .literal
        default: word.first.map { $0.isNumber || $0 == "-" } == true ? .number : .plain
        }
    }
}
