import Testing
@testable import Domain

@Suite("URL path spelling")
struct PathPatternTests {
    @Test("Literal routes match the URL-encoded request that clients send", arguments: [
        ("/café", "/caf%C3%A9"),
        ("/literal{brace}", "/literal%7Bbrace%7D"),
        ("/雪/😀", "/%E9%9B%AA/%F0%9F%98%80"),
        ("/caf%c3%a9", "/caf%C3%A9"),
        ("/percent%", "/percent%25"),
        ("/\u{0301}name", "/%CC%81name"),
        ("/cafe\u{0301}", "/cafe%CC%81"),
    ])
    func encodedLiteralMatches(pattern: String, request: String) {
        #expect(PathPattern.matches(requestPath: request, pattern: pattern))
        #expect(PathPattern.matchingKey(for: pattern) == PathPattern.matchingKey(for: request))
    }

    @Test("Escaping cannot change route structure or wildcard meaning", arguments: [
        ("/a/b", "/a%2Fb"),
        ("/a%2Fb", "/a/b"),
        ("/%3Aid", "/anything"),
        ("/%3A", "/anything"),
        ("/a%252Fb", "/a%2Fb"),
        ("/a:b", "/a%3Ab"),
        ("/caf%C3%A9", "/Caf%C3%A9"),
        ("/%FF", "/%FE"),
        ("/café", "/cafe%CC%81"),
    ])
    func distinctPathsRemainDistinct(pattern: String, request: String) {
        #expect(!PathPattern.matches(requestPath: request, pattern: pattern))
        #expect(PathPattern.matchingKey(for: pattern) != PathPattern.matchingKey(for: request))
    }

    @Test("Parameters still occupy exactly one segment beside encoded literals")
    func encodedRoutesKeepParameterSpecificity() {
        #expect(PathPattern.specificity(requestPath: "/caf%C3%A9/a%2Fb?sort=name", pattern: "/café/:id") == 1)
        #expect(PathPattern.specificity(requestPath: "/caf%C3%A9/a/b", pattern: "/café/:id") == nil)
        #expect(PathPattern.matchingKey(for: "/café/:id") == ["caf%C3%A9", ":"])
        #expect(PathPattern.matchingKey(for: "/%3A") == ["%3A"])
        #expect(PathPattern.matches(requestPath: "/name?\u{0301}ignored", pattern: "/name"))
    }
}
