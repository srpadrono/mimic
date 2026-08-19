import Foundation

/// Turning a logged request into an endpoint that would have answered it.
///
/// **This is a rule, and it was living in a view.** `RequestLogQuery.mockablePath` and the name
/// synthesis in `WorkspaceView` are what the drawer's "Create endpoint from this call" uses, and both
/// sat in `AppFeatures`. `MimicCLICore` depends on Domain and ArgumentParser only — it cannot reach
/// either — so a CLI `endpoint create-from-log` would have had to reimplement the query-stripping and
/// the naming, and the window and the script would then produce differently-named endpoints from the
/// same call.
///
/// Note what is deliberately *not* here: the execution. The request log is not part of `MockProject`,
/// so this cannot run inside `ProjectCommandExecutor`, whose signature is
/// `(ControlCommand, inout MockProject) -> ControlResult`. The host resolves a log id to one of these
/// and then issues an ordinary `.endpointCreate` — which is the same shape the existing
/// capture-a-journey flow already uses, and it keeps the executor the only place a project changes.
public enum EndpointFromLog {

    /// The route an endpoint would need in order to match this request.
    ///
    /// Strips the query string, because a query is not part of a route in this matcher — an endpoint
    /// created from `/orders?page=2` must match `/orders?page=3` as well, or the "create endpoint from
    /// this call" affordance produces something that does not answer the next call.
    public static func mockablePath(from path: String) -> String {
        // `split` omits empty subsequences, so a query-only path such as "?a=1" would come back as
        // "a=1" — not a route at all. Cut at the separator instead.
        let withoutQuery = path.firstIndex(of: "?").map { String(path[path.startIndex..<$0]) } ?? path
        return withoutQuery.hasPrefix("/") ? withoutQuery : "/"
    }

    /// The name to give an endpoint created from this call.
    ///
    /// `"GET /orders"` — the method and the route, which is what the sidebar shows and what a user
    /// would have typed. Derived rather than asked for, because the affordance's whole value is that
    /// it is one click from an unmatched row.
    public static func suggestedName(method: HTTPMethod, path: String) -> String {
        "\(method.rawValue) \(mockablePath(from: path))"
    }

    /// Everything needed to create the endpoint, derived from one logged request.
    public struct Draft: Equatable, Sendable {
        public let name: String
        public let method: HTTPMethod
        public let path: String

        public init(name: String, method: HTTPMethod, path: String) {
            self.name = name
            self.method = method
            self.path = path
        }
    }

    /// Derive a draft from a logged request. The single answer both surfaces use.
    public static func draft(from log: RequestLog) -> Draft {
        let path = mockablePath(from: log.path)
        return Draft(name: suggestedName(method: log.method, path: log.path), method: log.method, path: path)
    }
}
