import Foundation
import Domain
import DesignSystem

/// Turns a logged request back into something you can paste elsewhere.
///
/// The request log's job is not finished when it shows you a call: the next thing you do with a
/// request is almost always reproduce it — in a terminal, in a bug report, against the real backend
/// to compare. A single "copy everything as text" button made that a manual retyping job, so the
/// formats here are the ones people actually paste.
enum RequestLogExport {

    /// A `curl` invocation for the logged request, or a non-executable explanation when the log
    /// cannot reproduce it. The inspector disables copying in that case too.
    ///
    /// Uses `localhost` and the port the server is on rather than the log's bare path, because a
    /// command you have to finish editing before it runs is not much better than no command.
    nonisolated static func curl(for log: RequestLog, port: Int?) -> String {
        if let issue = curlUnavailability(for: log) { return "# \(issue)" }
        var lines: [String] = []

        let base = port.map { "http://localhost:\($0)" } ?? ""
        // Quoting protects the shell, not curl's own URL globbing and dot-segment normalization.
        // --head also changes response handling; -X HEAD alone still waits for a response body.
        let method = log.method == .head ? "--head" : "-X \(log.method.rawValue)"
        lines.append("curl --globoff --path-as-is \(method) \(shellQuoted(base + log.path))")

        // Sorted so two copies of the same request produce the same text — a diff between them
        // should show what actually changed, not a reshuffled dictionary.
        let connectionHeaders = Set(log.requestHeaders
            .filter { $0.key.lowercased() == "connection" }
            .flatMap { $0.value.lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } })
        let framingHeaders: Set<String> = [
            "connection", "content-length", "keep-alive", "proxy-connection",
            "te", "trailer", "transfer-encoding", "upgrade",
        ]
        let headers = log.requestHeaders.sorted(by: { $0.key < $1.key }).filter {
            !framingHeaders.contains($0.key.lowercased()) && !connectionHeaders.contains($0.key.lowercased())
        }
        for (key, value) in headers {
            // A colon with no value suppresses a header in curl. A semicolon sends an empty one.
            let header = value.isEmpty ? "\(key);" : "\(key): \(value)"
            lines.append("  -H \(shellQuoted(header))")
        }

        // These defaults could change a mock's header match even though the original request did
        // not send them. Content-Type is synthesized when --data-raw provides the body.
        let headerNames = Set(headers.map { $0.key.lowercased() })
        var defaultHeaders = ["Accept", "User-Agent"]
        if log.requestBody?.isEmpty == false { defaultHeaders.append("Content-Type") }
        for header in defaultHeaders where !headerNames.contains(header.lowercased()) {
            lines.append("  -H \(shellQuoted("\(header):"))")
        }

        if let body = log.requestBody, !body.isEmpty {
            lines.append("  --data-raw \(shellQuoted(body))")
        }

        return lines.joined(separator: " \\\n")
    }

    nonisolated static func curlUnavailability(for log: RequestLog) -> String? {
        if log.requestBodyTruncated == true {
            return "The request body was truncated; a complete cURL command is unavailable."
        }
        if log.requestBody?.utf8.contains(0) == true {
            return "The request body contains a null byte and cannot be copied as a shell argument."
        }
        if log.method == .head, log.requestBody?.isEmpty == false {
            return "A HEAD request with a body cannot be reproduced with cURL's header-only mode."
        }
        return nil
    }

    /// Wraps a string for `sh` in single quotes.
    ///
    /// Single quotes are literal in POSIX shells with exactly one exception — they cannot contain a
    /// single quote — so the embedded ones are closed, escaped, and reopened. A bearer token or a
    /// JSON body with an apostrophe is otherwise a command that silently runs wrong.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Pretty-prints a body when it parses as JSON, and returns it untouched when it does not.
    ///
    /// A mock's response is very often minified JSON, which is one long line. Displaying it verbatim
    /// is what made the old detail pane unreadable even when it had room.
    nonisolated static func formattedBody(_ body: String) -> String {
        JSONFormatter.prettyPrinted(body) ?? body
    }
}
