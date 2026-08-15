---
name: mimic-control-surface
description: The Definition of Done for adding or changing a Mimic operation across `ControlCommand`, `CommandKind`, `ProjectCommandExecutor`, `AppControlHost`, `CommandCatalog` and the `mimic` CLI — including which steps the compiler enforces, which only tests enforce, the exit-code contract, and the loopback/token boundary. Use when adding a command or CLI verb, editing the control plane or `MimicCLICore`, or changing discovery-file, token or `mimic app stop` behaviour.
---

# CLI and Control Plane — Definition of Done

Every operation that is a function of the open project is applied by `ProjectCommandExecutor` in
Domain. The CLI, the HTTP control API, and the app window all call it — see AGENTS.md, "One
implementation of the rules". This skill is the checklist for adding to that surface.

When adding or changing an operation:

1. **Add a `ControlCommand` case** with labelled associated values (unlabelled ones encode as `_0`).
2. **Add the matching `CommandKind` case.** `ControlCommand.kind` switches onto it with no `default`,
   so this is not optional — the build fails until it is there. That is the point: `ControlCommand`
   carries associated values and can never be `CaseIterable`, so `CommandKind` is the thing that
   *can* be, and it is what every list claiming to mirror the surface is checked against.
3. **Classify it in `CommandKind.scope`.** This one is also compile-enforced: `scope` is a
   non-optional property whose switch has no `default` either, so the build stays broken until you
   have said whether the command is `.project` (a pure function of the open document) or `.host`
   (server lifecycle, project selection, the live journey cursor, the request log).
4. **Handle it in `ProjectCommandExecutor`** if it is project-scoped; otherwise in
   `AppControlHost` — the one production `ControlHost` since the owner deleted the unreachable
   second one (see [`references/one-host.md`](references/one-host.md)).

   **This step is not compile-enforced, and the documentation claimed for a long time that it was.**
   Both dispatch switches end in a `default:` — `ProjectCommandExecutor.apply` and
   `AppControlHost.perform` (which has a second one in its project-lifecycle switch). Check it
   yourself in one command:

   ```bash
   grep -n 'default:' Sources/Domain/Control/ProjectCommandExecutor.swift \
                      Sources/AppFeatures/AppCore/AppControlHost.swift
   ```

   The tails are deliberate, and the reason is written above each of them: each switch is over
   `ControlCommand` while its caller has already narrowed by `CommandKind`, so the compiler cannot
   see the narrowing, and closing a switch would mean re-listing every case it declines. That list
   written out per switch is exactly what `scope` was introduced to collapse into one place, and no
   count of either side belongs in a document: `scope` is where the partition is decided and the
   only place it should be read. What each `default:` does instead is **name the command and say
   which switch declined it** — `"<kind> is project-scoped but ProjectCommandExecutor does not apply
   it."`, `"<kind> is host-scoped but the app's control host does not implement it."`, `"<kind> is
   not a project-lifecycle command."` — rather than falling through to `noProjectOpen` and telling a
   caller to open a project they already have open. They do not all do it the same way, and that
   matters when you go hunting for one: the executor **throws**, being a `throws` function, while
   both of the host's **return `.failure(…)`**, so one misrouted command surfaces as a thrown
   `ControlError` on one side of the line and as an `ok: false` response on the other. The code is
   `internal.failure` either way, which is what the sweeps below assert on.

   So the compiler forces you to **classify** a command; tests force you to **implement** it, on
   both sides of the line:

   - `Tests/DomainTests/ControlCommandTests.swift` runs a sample of every kind through the executor
     from both directions — `hostScopedCommandsReturnNil` requires every host-scoped kind to be
     declined, `projectScopedCommandsAreApplied` requires every project-scoped kind to be answered —
     failing specifically on the error code `internal.failure`, which is the executor's `default:`
     saying in as many words that it has no arm for the command.
   - `Tests/MimicTests/HostCommandSweepTests.swift` does the same for the host, which has no compile
     check at all: `everyHostScopedCommandIsRouted` walks `CommandKind.allCases` through
     `AppControlHost` with nothing open, `everyHostScopedCommandIsRoutedWithAProjectOpen` repeats it
     with a project seeded — nothing skipped, `serverStart` included, since the sweep's engine is a
     stub that binds no port — and each asserts the host did not answer from its unimplemented arm.
     It also mirrors the executor sweep, so one file covers the whole partition.
   - `Tests/MimicCLICoreTests/ControlTransportTests.swift` drives a list of `mimic` invocations
     through a recording transport and requires every `CommandKind` to have been emitted by one of
     them — so a command with no CLI verb fails there.
5. **Add a sample in the two places that hold one.** `HostCommandSweepTests.sample(for:)` is a
   switch over `CommandKind` with **no `default`**, so a new kind stops `MimicTests` compiling until
   you supply a payload — which is what keeps the sweeps above from quietly ceasing to cover the
   newest command.
   `ControlCommandSamples.all` in `DomainTests` is the same list for the executor's sweeps, and being
   an array it is checked rather than compiled: `everyCommandHasASample` compares it against
   `CommandKind.allCases` and fails naming what is missing.

   The duplication is real and deliberate — a test target is a module, and `MimicTests` cannot import
   `DomainTests` — but both copies are held to `allCases`, which is the difference between two lists
   that must agree and two lists that will drift. It is the failure those lists were built out of:
   the previous hand-written ones named fifteen of the twenty-one host-scoped commands and read as
   complete.
6. **Add a `CommandCatalog` descriptor.** `catalogCoversTheSurface` in `DomainTests` compares the
   catalog against `CommandKind.allCases`, so a missing entry fails the tests rather than silently
   shipping an undiscoverable command. It used to compare the catalog against a set of string
   literals written in the test itself — a fourth hand-maintained copy of the case list, so
   forgetting the catalog and forgetting the literals were the same omission and the test passed.
7. **Add the CLI subcommand** and a parse test in `MimicCLICoreTests`.

   The catalog indexes *control commands*, not CLI verbs, and the two are deliberately not one-to-one.
   Four verbs have no catalog entry and should not get one: `mimic app start`, `mimic app stop`,
   `mimic daemon start` and `mimic daemon stop` act on the OS process — launching the bundle,
   `SIGTERM`-ing a pid — and a command is by definition something a *running* instance is asked to do,
   so there is nobody to ask. Another three have no entry because they are compositions of entries
   that exist: `mimic journey export` is a `journeyGet` rendered as a spec, `mimic journey import` is
   a `journeyGet` then a `journeyCreate` or `journeyUpdate`, and `mimic journey deactivate` is
   `journeyActivate` with no name. Everything else the CLI can do maps onto exactly one `CommandKind`
   case — 47 of them as this is written, which
   `awk '/^public enum CommandKind/,/^}/' Sources/Domain/Control/CommandKind.swift | grep -c '^    case '`
   will confirm and `CommandCatalog.descriptors` matches one for one.

   **No test asserts that number any more, and none should.** `DomainTests` used to end on
   `CommandKind.allCases.count == 47`; it was a hand-edited mirror of a fact the type system already
   knows, so adding a command and bumping the literal was one edit and the assertion only ever caught
   somebody who had not run the suite. What it was reaching for is asserted structurally instead —
   every kind has a sample, a catalog entry, and an executor answer that agrees with its declared
   scope.
8. **Keep the exit-code contract**: `0` success, `2` bad usage, `3` no Mimic to talk to, `4` the
   command reached Mimic and did not come back with a result. Assert it at the process boundary —
   `MimicCommand.run(arguments:)` — and not only on `CLIFailure.exitCode`. Usage errors never become
   a `CLIFailure` at all; they come from ArgumentParser, whose own status is `EX_USAGE`, so `mimic
   nonsense` exited 64 against a documented 2 while every `CLIFailure` assertion stayed green.

   `3` is deliberately wider than "no reachable instance": `CLIFailure.appUnavailable` joins
   `noInstance` and `unreachable` there, so *Mimic.app is not installed where the CLI looked*, *it
   would not launch*, and *the pid in the discovery file could not be confirmed or signalled* all
   exit `3` too. They used to be `badArgument` — exit `2` — which told a script the user had mistyped
   something when what had actually happened was that there was no Mimic. Adding a fifth code was the
   alternative and was rejected: `3` already means "there is no Mimic to talk to", and inside `mimic
   app start` the not-installed failure and the never-answered failure are one condition that was
   being reported under two codes. Keep the contract at four values.
9. **Parse enum-valued options with `try`, never `try?`.** A swallowed conversion writes `nil` over
   the field and reports success, so `--match-mode sequential` told the caller it had changed a mode
   it had not touched.
10. **Never widen the control plane's binding** beyond `127.0.0.1`, and treat the discovery file as
    a credential. The full boundary — the `0600` write, token pairing, and what `mimic app stop`
    confirms before it signals — is in [`references/loopback-security.md`](references/loopback-security.md).
    Read it before touching any of them.

## References

| File | Read it when |
|------|--------------|
| [`references/loopback-security.md`](references/loopback-security.md) | Touching the discovery file, the token, `--url`, or `mimic app stop` |
| [`references/one-host.md`](references/one-host.md) | Adding a host-scoped command, or wondering why `ControlPlane` may not link Persistence or the engine |
