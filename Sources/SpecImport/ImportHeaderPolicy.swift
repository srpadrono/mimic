import Domain
import Foundation

/// Which response headers survive an import.
///
/// A capture records how *those particular bytes* reached *that particular client* on *that
/// particular connection*. Mimic re-frames and re-sends the body itself, so replaying those headers
/// describes a transfer that is not happening.
///
/// `Content-Encoding` is the one that actually breaks things. A HAR entry captured from a real
/// server almost always carries `Content-Encoding: gzip` (or `br`, or `deflate`), while the body HAR
/// stores — and therefore the body Mimic serves — is the *decoded* text. Replaying the header makes
/// every client try to gunzip plain JSON, and the request fails before any test assertion runs.
///
/// The rest are hop-by-hop headers (RFC 9110 §7.6.1): meaningful only for a single connection, never
/// correct to forward. `Content-Length` and `Content-Range` are dropped for the same reason — the
/// server computes the real length, and a captured byte range does not describe the body being sent.
///
/// Credentials are dropped separately, against ``RequestLog/sensitiveHeaderNames``: an imported mock
/// is committed to a repository and shared, and a captured `Authorization` header or session cookie
/// has no business travelling with it.
public enum ImportHeaderPolicy {

    /// Headers describing the original transfer rather than the response itself.
    static let transportHeaders: Set<String> = [
        "content-encoding",
        "content-length",
        "content-range",
        "transfer-encoding",
        "connection",
        "keep-alive",
        "upgrade",
        "te",
        "trailer",
        "proxy-authenticate",
        "proxy-authorization",
    ]

    /// Headers describing the moment of capture, which would be stale and misleading if replayed.
    static let capturedAtHeaders: Set<String> = [
        "date",
        "server",
        "age",
    ]

    // Credentials and session state are *not* listed here. There is one list of what counts as a
    // credential, ``RequestLog/sensitiveHeaderNames`` in Domain, and this policy reads it.
    //
    // This file used to carry its own four — `authorization`, `proxy-authorization`, `cookie`,
    // `set-cookie` — while Domain's six added `x-api-key` and `x-auth-token`. A strict subset, and
    // the wrong way round: Domain's list only redacts the request log, which is the developer's own
    // traffic on the developer's own screen, while this one decides what gets written into an
    // endpoint that may then be committed to a repository. So an imported `X-Auth-Token` — which a
    // login response is exactly the thing that carries — was redacted from the log and replayed into
    // a checked-in mock. The narrower list was guarding the riskier path.
    //
    // If a name is ever credential-bearing on an import but not in a log, add it here as a union
    // with Domain's and say which side is which. There is no such name today.
    //
    // Still deliberately *not* a credential on either side: `WWW-Authenticate`. It is a challenge,
    // not a secret — mocking a 401 that tells the client how to authenticate is a legitimate thing
    // to want, and ``RequestLog/sensitiveHeaderNames`` does not list it either.

    /// `true` when a header should not be copied onto an imported mock.
    ///
    /// HTTP/2 pseudo-headers (`:status`, `:method`) are dropped too: they are framing, not headers,
    /// and are not legal to send back.
    public static func shouldDrop(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix(":") { return true }
        return transportHeaders.contains(lower)
            || capturedAtHeaders.contains(lower)
            // Passed the untouched name: Domain owns both the list and how a name is normalised
            // against it, and a second normalisation here is a second thing that can drift.
            || RequestLog.isSensitiveHeader(name)
    }

    /// Keeps only the headers that describe the response itself.
    public static func replayable(_ headers: [String: String]) -> [String: String] {
        headers.filter { !shouldDrop($0.key) }
    }
}
