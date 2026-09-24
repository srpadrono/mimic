import Foundation

/// Re-indents and classifies JSON for display, without ever reparsing it.
///
/// The obvious implementation — `JSONSerialization` in, `.prettyPrinted` out — is wrong for a
/// traffic log. Round-tripping through a dictionary loses the payload's key order, so the body you
/// read here would not be the body that went over the wire; with `.sortedKeys` it is reordered
/// outright. When you are staring at a response asking why the client mis-parsed it, "the keys are
/// in a different order than the server sent" is exactly the kind of lie the tool must not tell.
///
/// So this is a character scanner. It rewrites whitespace between tokens and touches nothing else,
/// which also means it degrades gracefully: a truncated body (the log caps at 64 KB) still formats,
/// where a parser would simply refuse.
public nonisolated enum JSONFormatter {

    /// What a run of characters is, for colouring.
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

    /// Bodies above this are shown verbatim. Formatting is linear, but a 64 KB body still turns into
    /// tens of thousands of `AttributedString` runs, and that cost lands on every body evaluation.
    public static let formattingLimit = 20 * 1024

    /// A compact body can expand quadratically when each nested container adds another indented
    /// line. Keep one malformed or unusually deep response from allocating an enormous rendered
    /// body; callers show the original text when formatting returns `nil`.
    static let maxFormattedBytes = 256 * 1024

    /// `true` when the text is worth treating as JSON at all.
    public nonisolated static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    /// A re-indented copy, or `nil` when the text is not JSON — or, unless `reflow` is set, when it
    /// is already laid out across lines, or when indentation would exceed the output budget.
    ///
    /// `reflow` exists because the two callers want opposite things from the same scanner. The
    /// traffic log *displays* a body it did not write, so text already broken across lines is a
    /// layout somebody chose and reflowing it would fight that choice — the default. The editor's
    /// Format button is an explicit instruction to lay the body out, and refusing it because the
    /// body already contains a newline made the button a no-op on exactly the payloads that need it
    /// most: the tab-indented, the eight-space-indented, and anything already formatted once.
    public nonisolated static func prettyPrinted(_ text: String, reflow: Bool = false) -> String? {
        guard looksLikeJSON(text) else { return nil }
        guard reflow || !text.contains("\n") else { return nil }

        var output = ""
        output.reserveCapacity(min(text.utf8.count, maxFormattedBytes))
        var outputBytes = 0

        let characters = Array(text)
        var depth = 0
        var index = 0

        func append(_ fragment: String) -> Bool {
            let fragmentBytes = fragment.utf8.count
            guard fragmentBytes <= maxFormattedBytes - outputBytes else { return false }
            output.append(fragment)
            outputBytes += fragmentBytes
            return true
        }

        func appendNewline(indent: Int) -> Bool {
            let indent = max(0, indent)
            let remaining = maxFormattedBytes - outputBytes
            // Check before multiplying or constructing the indentation string.
            guard remaining > 0, indent <= (remaining - 1) / 2 else { return false }
            output.append("\n")
            output.append(String(repeating: "  ", count: indent))
            outputBytes += 1 + 2 * indent
            return true
        }

        /// The next character that is not whitespace, without consuming it.
        func peekNonWhitespace(from start: Int) -> Character? {
            var probe = start
            while probe < characters.count, characters[probe].isWhitespace { probe += 1 }
            return probe < characters.count ? characters[probe] : nil
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                let (literal, next) = scanString(characters, from: index)
                guard append(String(literal)) else { return nil }
                index = next
                continue
            }

            switch character {
            case "{", "[":
                guard append(String(character)) else { return nil }
                // An empty container stays on one line — `{\n}` is noise, not structure.
                let closing: Character = character == "{" ? "}" : "]"
                if peekNonWhitespace(from: index + 1) == closing {
                    var probe = index + 1
                    while characters[probe].isWhitespace { probe += 1 }
                    guard append(String(closing)) else { return nil }
                    index = probe + 1
                    continue
                }
                depth += 1
                guard appendNewline(indent: depth) else { return nil }

            case "}", "]":
                depth -= 1
                guard appendNewline(indent: depth), append(String(character)) else { return nil }

            case ",":
                guard append(String(character)), appendNewline(indent: depth) else { return nil }

            case ":":
                guard append(": ") else { return nil }

            default:
                guard !character.isWhitespace else { break }
                guard append(String(character)) else { return nil }
            }

            index += 1
        }

        return output
    }

    /// Splits text into coloured runs. Non-JSON text comes back as a single `.plain` token, so
    /// callers do not need to branch.
    public nonisolated static func tokenize(_ text: String) -> [Token] {
        guard looksLikeJSON(text) else { return [Token(text: text, kind: .plain)] }

        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        var pending = ""

        func flushPending() {
            guard !pending.isEmpty else { return }
            tokens.append(Token(text: pending, kind: kindOfBareWord(pending)))
            pending = ""
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                flushPending()
                let (literal, next) = scanString(characters, from: index)
                // A string is a key when a colon follows it — the only thing that distinguishes the
                // two in JSON, and worth distinguishing because keys are what you scan for.
                var probe = next
                while probe < characters.count, characters[probe].isWhitespace { probe += 1 }
                let isKey = probe < characters.count && characters[probe] == ":"
                tokens.append(Token(text: String(literal), kind: isKey ? .key : .string))
                index = next
                continue
            }

            if "{}[]:,".contains(character) {
                flushPending()
                tokens.append(Token(text: String(character), kind: .punctuation))
                index += 1
                continue
            }

            if character.isWhitespace {
                flushPending()
                tokens.append(Token(text: String(character), kind: .plain))
                index += 1
                continue
            }

            pending.append(character)
            index += 1
        }

        flushPending()
        return tokens
    }

    // MARK: - Scanning

    /// Consumes a quoted string starting at `start`, returning it with the index just past it.
    ///
    /// Escape handling is the whole point: a `\"` inside a value must not end the string, or every
    /// token after it is misclassified and the colouring drifts for the rest of the body.
    private nonisolated static func scanString(
        _ characters: [Character],
        from start: Int
    ) -> (literal: [Character], next: Int) {
        var literal: [Character] = ["\""]
        var index = start + 1
        var isEscaped = false

        while index < characters.count {
            let character = characters[index]
            literal.append(character)
            index += 1

            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                break
            }
        }

        return (literal, index)
    }

    private nonisolated static func kindOfBareWord(_ word: String) -> TokenKind {
        switch word {
        case "true", "false", "null": .literal
        default: word.first.map { $0.isNumber || $0 == "-" } == true ? .number : .plain
        }
    }
}
