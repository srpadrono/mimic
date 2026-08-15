# One host

`ControlHost` has exactly one production conformance: `AppControlHost` in `AppFeatures`, which maps
commands onto the live session. Every `mimic` invocation and every HTTP control call reaches it —
in a visible window and in headless mode alike, because headless is a *mode of the app*, not a
different process. Follow `mimic daemon start` and it ends up in the same place `mimic app start`
does: `DaemonCommand.Start` builds an `AppCommand.Start`, sets `headless = true` on it, and calls
its `run()`. That reaches `AppLauncher.launch(headless: true)`, which sets `MIMIC_HEADLESS=1` in the
child environment and executes `Mimic.app/Contents/MacOS/Mimic` — the app bundle. Inside it,
`HeadlessMode` drops the activation policy to `.accessory` and `ControlPlaneCoordinator.start`
stands up `ControlServer(host: AppControlHost(…), mode: "headless")`. The `"headless"` in the
discovery file and in `mimic ping`'s reply names that mode.

**This section used to be called "Two hosts, one of them shipped — a known issue."** `ControlPlane`
carried a second conformance, `MimicControlService`, with a repository and an engine of its own, and
`MimicDaemon`, a windowless composition root beside it — built, better-tested than the shipped host,
and constructed by nothing in production. The duplication was the mechanism behind every divergence
between the window and the CLI that this repository has shipped, and it worked in the worst
direction: a green `ControlPlaneTests` was evidence about code the user never runs. The decision the
old section recorded as pending — wire the daemon up to a real binary, or delete it — was made by
the owner, and the answer was **delete**: headless Mimic runs the app bundle without windows, which
covers what a daemon was for, and "every rule implemented once" is worth more than a second binary
nobody had asked for. Both files, their direct tests, and the `HostParityTests` suite that drove
the two hosts side by side went with it; the git history keeps all of them if the daemon need ever
materialises.

Three things follow for anyone working here:

- **Do not grow the host back.** `ControlPlane` depends on Domain and Vapor alone, and
  `Scripts/check_module_edges.py` — a CI gate — fails on an edge onto Persistence or
  MockServerEngine from it, precisely because a store or an engine appearing under `ControlPlane`
  is a second host starting to regrow. If that is ever wanted, it is a decision to argue with the
  owner, not a dependency to add in passing.
- **When you add a command, the tests that matter are the `AppControlHost` ones.** The *compiler*
  does not force you to implement it — the host's dispatch switch ends in a `default:` that throws
  at runtime (see step 4 of the Definition of Done for exactly what is and is not compile-checked).
  `Tests/MimicTests/HostCommandSweepTests.swift` is what forces it: its sweeps
  drive every host-scoped kind through the host, with and without a project open, and fail if any
  answers from that arm.
- **`ControlServerTests` tests the HTTP layer, not the host.** It stands `ControlServer` on
  `LoopbackTestHost`, a fixture in the same file that routes project-scoped commands through the
  production executor and answers a handful of host-scoped arms with trivial glue. Host behaviour —
  persistence ordering, the engine, the write chain — is covered in `MimicTests` against
  `AppControlHost` itself, driven directly rather than over a socket.
