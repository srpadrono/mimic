import Domain

/// Anything that can answer a ``ControlCommand``.
///
/// Two things implement this: ``MimicControlService`` (owns a repository and an engine — what a
/// headless daemon runs) and, in the app, an adapter over the live session so the CLI drives the
/// same state the window shows. The HTTP server depends only on this protocol, so it neither knows
/// nor cares which one it is serving.
public protocol ControlHost: Sendable {
    /// Executes a command. Failures are returned as an unsuccessful ``ControlResponse`` rather than
    /// thrown: a control call always produces a reply the caller can parse.
    func execute(_ command: ControlCommand) async -> ControlResponse
}
