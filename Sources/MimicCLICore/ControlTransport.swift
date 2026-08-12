import Domain
import Foundation

/// What a `mimic` subcommand needs from a running instance: somewhere to send a `ControlCommand`,
/// and an answer back.
///
/// This exists to put a seam under the transport. `ControlClient` builds its own `URLSession` inside
/// its initialiser and `GlobalOptions.client()` handed back that concrete type, so there was no
/// point at which a test could stand between a subcommand and the network. Two things followed, and
/// both were invisible: no verb's emitted `ControlCommand` could be asserted — the command is built
/// and posted in one expression, `options.client().send(.ping)` — and none of `ControlClient.send`'s
/// five branches (envelope-first decode, `401`, non-2xx, an undecodable 2xx, a transport failure) had
/// ever been executed by a test. `Tests/MimicCLICoreTests` is the only suite that imports this module
/// at all, and it never calls `send` or `isReachable`: what it asserts about those branches is the
/// exit code each *failure value* carries, which is a different statement about a different thing.
///
/// Deliberately the whole of what the CLI asks of an instance and nothing more: `send` is what every
/// subcommand calls, `isReachable` is what `mimic app start` waits on and `mimic app status`
/// reports, and `baseURL` is what both of those name in their output. A wider protocol would start
/// describing `ControlClient` instead of describing what a command needs.
public protocol ControlTransport: Sendable {
    /// Where this transport is pointed. Reported by `mimic app start` and `mimic app status`, and
    /// named in the "Could not reach Mimic at …" failure.
    var baseURL: URL { get }

    /// Sends one command and returns Mimic's envelope. Throws `CLIFailure` when no envelope came
    /// back at all — a refusal *inside* an envelope is a successful send with `ok: false`.
    func send(_ command: ControlCommand) async throws -> ControlResponse

    /// Whether an instance answers. A `401` counts as reachable — see `ControlClient.isReachable`.
    func isReachable() async -> Bool
}

/// The transport every command reaches for when a test has put one there, and nothing at all when
/// one has not.
///
/// A task-local rather than a stored property or a mutable static, for two reasons. ArgumentParser
/// builds each subcommand out of argv — `MimicCommand.run` calls `parseAsRoot` and every subcommand
/// takes its dependencies as `@OptionGroup var options: GlobalOptions` — so there is no call site
/// where a test could hand a transport in. And a mutable global would be shared mutable state in a
/// module that compiles nonisolated, so two suites running in parallel would overwrite each other's
/// stub. `withValue` scopes the binding to one task tree and the value propagates into the child
/// tasks a command creates, which is what `Tests/ControlPlaneTests/ControlServerTests.swift` already
/// leans on to carry the token of the server a given test is talking to.
///
/// Nothing in production binds it. `MimicCommand.run` does not, so `current` is `nil` for every real
/// invocation and `GlobalOptions.client()` builds exactly the client it built before this existed.
///
/// ```swift
/// try await ControlTransportOverride.$current.withValue(recorder) {
///     _ = await MimicCommand.run(arguments: ["endpoint", "list"])
/// }
/// ```
public enum ControlTransportOverride {
    @TaskLocal public static var current: (any ControlTransport)?
}
