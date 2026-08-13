import Domain

/// Anything that can answer a ``ControlCommand``.
///
/// In production exactly one thing implements this: `AppControlHost` in `AppFeatures`, the adapter
/// over the live session, so the CLI drives the same state the window shows — in a visible window
/// and in headless mode alike, which are two modes of the same process. There used to be a second
/// conformance here, `MimicControlService`, a self-contained service with a store and an engine of
/// its own that nothing in production ever constructed; the owner resolved that fork by deleting it
/// (AGENTS.md, "One host"). The protocol stays because it is the seam: ``ControlServer`` depends
/// only on this, so the HTTP layer is testable against a stub without standing up an app session.
public protocol ControlHost: Sendable {
    /// Executes a command. Failures are returned as an unsuccessful ``ControlResponse`` rather than
    /// thrown: a control call always produces a reply the caller can parse.
    func execute(_ command: ControlCommand) async -> ControlResponse
}
