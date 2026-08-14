import Foundation

/// Turns the route a spec *writes* into a route Mimic can *match*.
///
/// Two rules live here and nowhere else, because `ImportCandidateBuilder.makeCandidate` is their
/// only caller and every importer goes through it. Written once per parser they would drift, which
/// is the whole reason that builder exists.
///
/// **Wildcards.** `PathPattern.specificity` in Domain reads a segment as a wildcard only when it
/// starts with `:`. OpenAPI and Swagger write a parameter as `{id}`. Nothing converted between the
/// two, so `/api/users/{id}` imported as three *literal* segments and a request for
/// `/api/users/42` could never match it — the endpoints appeared in the sidebar and 404'd forever.
///
/// **The document's prefix.** A spec declares once, at the top, the path everything in it hangs
/// off: `basePath` in Swagger 2, `servers[].url` in OpenAPI 3. `basePath` was decoded and read
/// nowhere, and `servers` was not decoded at all, so a document declaring `basePath: /v2` imported
/// `/pet/{petId}` for a server that answers `/v2/pet/42` — even its literal routes were wrong.
enum ImportPath {
    /// The marker Domain's `PathPattern` reads a wildcard segment by. Named here so the two places
    /// that depend on it — ``wildcarded(segment:)`` below and
    /// `ImportCandidateBuilder.meaningfulSegments` — cannot come to disagree about it.
    static let wildcardMarker = ":"

    /// The path an imported endpoint gets: the document's prefix, then the route, with every
    /// whole-segment `{parameter}` rewritten to `:parameter`.
    static func normalized(_ path: String, documentBasePath: String?) -> String {
        join(prefix: prefix(fromDocumentBasePath: documentBasePath), route: route(path))
    }

    /// One route in Mimic's wildcard syntax, carrying no document prefix.
    ///
    /// This — not ``normalized(_:documentBasePath:)`` — is what a candidate's suggested name and
    /// group tag are derived from. A document served under `/mock` would otherwise tag every
    /// endpoint in it "Mock" and name half of them after it.
    static func route(_ path: String) -> String {
        // `omittingEmptySubsequences: false` so the string's shape survives the round trip: the
        // leading `/` comes back, and a route a spec wrote with a trailing slash keeps it.
        // Rebuilding from non-empty segments would quietly rewrite `/pets/` to `/pets` for every
        // spec that has one — a change to what an already-working route imports as, buying nothing,
        // since `PathPattern` splits the empty segments away itself.
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { wildcarded(segment: String($0)) }
            .joined(separator: "/")
    }

    /// One path segment, in Mimic's syntax. Four decisions, all deliberate:
    ///
    /// - `{petId}` becomes `:petId`. A whole-segment parameter is the only shape `PathPattern` can
    ///   act on, and it is the shape both spec formats overwhelmingly write.
    /// - `{}` becomes `:param`. A nameless parameter is still a parameter, and the text after the
    ///   colon is decoration — `PathPattern.specificity` reads the `:` and nothing else. Leaving
    ///   `{}` literal would be a segment no request can ever equal.
    /// - A segment already starting with `:` is returned untouched, by falling through the `{`
    ///   guard. A spec emitted by a tool that writes Express-style routes already says what Mimic
    ///   says; translating an already-translated route is how `::id` gets shipped.
    /// - **A partial segment is left verbatim, as a literal.** `/files/{name}.json`, `v{major}` and
    ///   `{a}-{b}` cannot be expressed: matching is segment-wise, so the only wildcard available
    ///   covers the entire segment, and `:name` there would also answer `/files/report.xml` — a
    ///   route the spec never described. Importing it literally leaves something that 404s until
    ///   someone edits the path, which is visible; importing it as a wildcard silently answers
    ///   requests that were never in the document. `ImportedRouteMatchingTests` pins both halves of
    ///   that, so the choice is asserted rather than merely described.
    ///
    /// The name is reduced to letters, numbers, `_`, `-` and `.`; anything else a spec puts inside
    /// the braces (RFC 6570 modifiers like `{petId*}`, stray whitespace) is dropped, and a name left
    /// empty by that falls back to `param`.
    static func wildcarded(segment: String) -> String {
        // No length check beside these: no single character is both `{` and `}`, so anything passing
        // both has an interior for `dropFirst().dropLast()` to take, even if it is empty.
        guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return segment }
        let inner = segment.dropFirst().dropLast()
        // A segment holding more than one parameter, or a stray brace, is the partial case above.
        guard !inner.contains("{"), !inner.contains("}") else { return segment }
        let name = String(inner.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        return name.isEmpty ? "\(wildcardMarker)param" : "\(wildcardMarker)\(name)"
    }

    /// The prefix every route in a document hangs off, reduced to `""` or a path starting with `/`
    /// and not ending in one.
    ///
    /// `""` — no prefix, nothing joined — for every form that names no path: absent, empty, `/`,
    /// and a server URL that stops at its host. `/` is the value every `basePath` fixture in
    /// `SpecImportTests` used to carry, and it is why a suite that size could not see the prefix
    /// being dropped: for `/` the correct answer and the broken one are the same string.
    ///
    /// **A server URL may be absolute**, which is the normal OpenAPI 3 shape
    /// (`https://petstore.swagger.io/v2`): only its *path* is a route prefix. The host names where
    /// the real service lives and has nothing to do with what Mimic answers on loopback, so it is
    /// discarded. Query and fragment are discarded for the same reason `HARParser.extractPath`
    /// discards them — they never participate in matching.
    static func prefix(fromDocumentBasePath raw: String?) -> String {
        guard let raw else { return "" }
        var candidate = pathComponent(ofServerURL: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let cut = candidate.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            candidate = String(candidate[..<cut])
        }
        while candidate.hasSuffix("/") { candidate = String(candidate.dropLast()) }
        guard !candidate.isEmpty else { return "" }
        // Rewritten like any other route: an OpenAPI 3 server may be `https://x.example.com/{tier}`,
        // and a prefix is not exempt from being matchable.
        return route(candidate.hasPrefix("/") ? candidate : "/" + candidate)
    }

    /// The path portion of a server URL, with any authority removed.
    ///
    /// Split by hand rather than parsed, because the input is not reliably a URL: OpenAPI 3 allows
    /// a *templated* server (`https://{region}.example.com/v1`), and braces sit outside every
    /// production RFC 3986 builds a URL from. Everything from the first `/` after the authority is
    /// the path; a URL that stops at its host has no path at all. A string with no authority
    /// (`/v2`, `v2`) is already the path.
    private static func pathComponent(ofServerURL raw: String) -> String {
        let afterAuthorityStart: Substring
        if let schemeRange = raw.range(of: "://") {
            afterAuthorityStart = raw[schemeRange.upperBound...]
        } else if raw.hasPrefix("//") {
            // Scheme-relative (`//api.example.com/v2`). Left unhandled it would prefix every route
            // with a host *and* a `//`, which `EndpointValidator.validatePath` rejects — so the
            // whole import would be refused rather than merely mis-routed.
            afterAuthorityStart = raw.dropFirst(2)
        } else {
            return raw
        }
        guard let slash = afterAuthorityStart.firstIndex(of: "/") else { return "" }
        return String(afterAuthorityStart[slash...])
    }

    /// Joins a reduced prefix to a rewritten route without ever producing `//`, which
    /// `EndpointValidator.validatePath` rejects on the commit path.
    private static func join(prefix: String, route: String) -> String {
        guard !prefix.isEmpty else { return route }
        // `/` and `""` are the same route, and both must leave `/v2` rather than `/v2/`.
        guard route != "/", !route.isEmpty else { return prefix }
        return route.hasPrefix("/") ? prefix + route : prefix + "/" + route
    }
}
