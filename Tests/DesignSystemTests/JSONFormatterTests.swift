import Testing
import DesignSystem

@Suite("JSONFormatter")
struct JSONFormatterTests {
    // MARK: - JSON layout

    @Test("Minified JSON is re-indented")
    func prettyPrintsMinifiedJSON() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"id":1,"name":"Ada"}"#))

        #expect(formatted == """
        {
          "id": 1,
          "name": "Ada"
        }
        """)
    }

    @Test("Key order survives formatting")
    func preservesKeyOrder() throws {
        // The reason this is a character scanner and not JSONSerialization: a round trip through a
        // dictionary reorders keys, so the body shown would not be the body served.
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"zebra":1,"apple":2,"mango":3}"#))
        let keys = formatted
            .split(separator: "\n")
            .compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }

        #expect(keys == ["zebra", "apple", "mango"])
    }

    @Test("Braces and brackets inside strings do not change indentation")
    func ignoresStructureInsideStrings() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"pattern":"{a,b}[c]","n":1}"#))

        #expect(formatted == """
        {
          "pattern": "{a,b}[c]",
          "n": 1
        }
        """)
    }

    @Test("An escaped quote does not end the string")
    func handlesEscapedQuotes() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"say":"he said \"hi\"","n":2}"#))

        #expect(formatted.contains(#""say": "he said \"hi\"""#))
        #expect(formatted.contains(#""n": 2"#))
    }

    @Test("Empty containers stay on one line")
    func keepsEmptyContainersInline() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"items":[],"meta":{}}"#))

        #expect(formatted == """
        {
          "items": [],
          "meta": {}
        }
        """)
    }

    @Test("Nested structures indent by depth")
    func indentsNestedStructures() throws {
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"a":{"b":[1,2]}}"#))

        #expect(formatted == """
        {
          "a": {
            "b": [
              1,
              2
            ]
          }
        }
        """)
    }

    @Test("Non-JSON and already-formatted bodies are left alone")
    func skipsWhatItShouldNotTouch() {
        #expect(JSONFormatter.prettyPrinted("plain text response") == nil)
        #expect(JSONFormatter.prettyPrinted("") == nil)
        #expect(JSONFormatter.prettyPrinted("<html><body>hi</body></html>") == nil)
        // Already laid out across lines — whoever produced it chose a layout.
        #expect(JSONFormatter.prettyPrinted("{\n  \"a\": 1\n}") == nil)
    }

    @Test("A truncated body still formats")
    func formatsTruncatedJSON() throws {
        // The log caps bodies at 64 KB, so a cut-off payload is a normal input here. A parser would
        // refuse it outright; the scanner has to degrade instead.
        let formatted = try #require(JSONFormatter.prettyPrinted(#"{"a":1,"b":"unterminat"#))

        #expect(formatted.hasPrefix("{\n  \"a\": 1,"))
    }

    // MARK: - Tokenising

    @Test("Keys, strings, numbers, and literals are told apart")
    func classifiesTokens() {
        let tokens = JSONFormatter.tokenize(#"{"name":"Ada","age":36,"active":true,"note":null}"#)

        func kind(of text: String) -> JSONFormatter.TokenKind? {
            tokens.first { $0.text == text }?.kind
        }

        #expect(kind(of: #""name""#) == .key)
        #expect(kind(of: #""Ada""#) == .string)
        #expect(kind(of: "36") == .number)
        #expect(kind(of: "true") == .literal)
        #expect(kind(of: "null") == .literal)
        #expect(kind(of: "{") == .punctuation)
    }

    @Test("A string is a key only when a colon follows it")
    func distinguishesKeysFromValues() {
        let tokens = JSONFormatter.tokenize(#"["alpha","beta"]"#)

        #expect(tokens.contains { $0.text == #""alpha""# && $0.kind == .string })
        #expect(tokens.contains(where: { $0.kind == .key }) == false)
    }

    @Test("Non-JSON tokenises as a single plain run")
    func tokenizesNonJSONAsPlain() {
        let tokens = JSONFormatter.tokenize("not json at all")

        #expect(tokens == [JSONFormatter.Token(text: "not json at all", kind: .plain)])
    }

    @Test("Tokens reassemble into the original text")
    func tokenizingIsLossless() {
        let source = #"{"a":[1,true,null],"b":"x y"}"#
        let rejoined = JSONFormatter.tokenize(source).map(\.text).joined()

        #expect(rejoined == source)
    }

    @Test("A small truncated nesting payload cannot expand into an oversized formatted body")
    func rejectsDeepTruncatedNesting() {
        // Only 701 input bytes, but indentation grows quadratically as nesting deepens.
        // Keep this fixture literal: a change to the production output budget must not silently
        // move the regression case along with it.
        let truncated = String(repeating: "[", count: 700) + "0"
        #expect(truncated.utf8.count == 701)
        #expect(JSONFormatter.prettyPrinted(truncated) == nil)
    }
}
