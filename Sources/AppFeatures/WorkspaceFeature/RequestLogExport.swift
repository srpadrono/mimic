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

    /// A `curl` invocation that reproduces the logged request against the running mock.
    ///
    /// Uses `localhost` and the port the server is on rather than the log's bare path, because a
    /// command you have to finish editing before it runs is not much better than no command.
    nonisolated static func curl(for log: RequestLog, port: Int?) -> String {
        var lines: [String] = []

        let base = port.map { "http://localhost:\($0)" } ?? ""
        lines.append("curl -X \(log.method.rawValue) \(shellQuoted(base + log.path))")

        // Sorted so two copies of the same request produce the same text — a diff between them
        // should show what actually changed, not a reshuffled dictionary.
        for (key, value) in log.requestHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("  -H \(shellQuoted("\(key): \(value)"))")
        }

        if let body = log.requestBody, !body.isEmpty {
            lines.append("  --data-raw \(shellQuoted(body))")
        }

        return lines.joined(separator: " \\\n")
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
