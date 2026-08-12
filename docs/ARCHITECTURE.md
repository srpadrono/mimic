# Architecture

Contributor- and AI-facing orientation for Mimic. Read this first: it gives the **domain language**
and the **why** behind the architecture, which is what makes the code read predictably.

Pairs with the [README](../README.md) for the overview, [JOURNEYS.md](JOURNEYS.md) and
[CLI.md](CLI.md) for the two automation surfaces in depth, [ROADMAP.md](ROADMAP.md) for the known
gaps, and [CONTRIBUTING.md](../CONTRIBUTING.md) for the build and test gates.

## What Mimic is

A native macOS app for iOS developers to run local mock API servers: define endpoints, configure
responses, switch scenarios, script journeys, simulate latency and network failures, and inspect live
request traffic — so frontend work can start before the backend exists. An embedded Vapor server runs
**in-process** (direct Swift calls, never HTTP-to-self).

It is also a testing platform: 47 operations — every project, server, endpoint, scenario, journey and
request-log operation the window performs — are available as commands, so UI tests, integration
tests, and AI agents can reproduce a whole application scenario without driving the UI. The one
workflow that is not a command is **spec import**: `SpecImport` is linked by `AppFeatures` alone, so
turning a HAR or an OpenAPI document into endpoints happens in the window and nowhere else. A script
parses the file itself and issues `endpointCreate` + `scenarioUpdate` per route — which is precisely
what `AppState.commitImportedCandidates` does after the review sheet is confirmed, so the rules
applied are the same either way.

## Domain language

Use these terms exactly; they are the names in code.

- **Project** (`MockProject`) — a named set of endpoints and journeys plus a `ServerConfiguration`
  (port + global delay). The unit of save/load and the unit a caller switches between.
- **Endpoint** — a method + path (`:param` wildcards allowed) owning one or more **Scenarios**, an
  `activeScenarioID`, an optional per-endpoint `delayMs`, and an optional `groupTag`.
- **Scenario** — one possible response (status code, headers, body, content type). Exactly one is
  *active* per endpoint; switching the active scenario changes what the server returns, live.
- **Journey** — an **ordered script of responses**. Endpoints answer "what does this route return?";
  a journey answers "what does it return *the second time*?". While active it overlays the endpoints,
  so the same route can fail and then succeed. Many are stored; at most one is active.
- **Journey step** — one scripted outcome: either a response (status/headers/body/delay/repeat) or a
  **transport failure** (`connectionDrop`, `timeout(holdMs:)`) — the cases a status code cannot express.
- **Journey run state** (`JourneyRunState`) — where a run stands: per-step serve counts, the cursor
  (always the first unexhausted step), and completion. A value type, replaced wholesale per request.
- **Request matching** (`RequestMatcher.match`) — picks the **most specific** endpoint for a request:
  more literal segments beat `:wildcard` segments, so `/users/me` wins over `/users/:id` regardless
  of declaration order; ties go to the first declared. Journey steps use the same `PathPattern` rules.
- **Response resolution** (`MockResolver.plan`) — the single place a request becomes a response. An
  active journey gets first refusal; whatever it declines falls through to endpoint resolution
  (`RequestMatcher.resolve`). Returns the concrete status/headers/body, the **effective delay**
  (`globalDelayMs + step-or-endpoint delay`, additive), and the journey state to store next. Pure and
  unit-tested.
- **Control command** (`ControlCommand`) — an operation as data. The vocabulary the CLI, the HTTP
  control API, and the app's own menus all speak.
- **Import candidate** (`ImportCandidate`) — a normalized endpoint proposal parsed from a HAR or
  OpenAPI source, reviewed before commit.

## Module map (deep modules, small surfaces)

```
Mimic (app) → AppFeatures → Domain
                          → Persistence      → Domain
                          → MockServerEngine → Domain (+ Vapor)
                          → ControlPlane     → Domain, Persistence, MockServerEngine (+ Vapor)
                          → SpecImport       → Domain
                          → DesignSystem     (SwiftUI only)

mimic (CLI) → MimicCLICore → Domain (+ ArgumentParser)
```

- **Domain** — value types + pure rules. Imports Foundation only. No SwiftUI/Vapor/GRDB. Holds:
  - models, `RequestMatcher`/`resolve`, validation
  - `JourneyResolver` / `JourneyRunState` / `MockResolver` — journey resolution as a pure function
  - `ControlCommand` / `ProjectCommandExecutor` — the command language and its pure interpreter
  - `CommandCatalog` — runtime self-description; `JourneyTemplates` — the built-in journey library
- **MockServerEngine** — `MockServerEngine` actor owns the Vapor app + a `MockRouteStore` snapshot of
  the live configuration *and the journey cursor*; serves requests by asking Domain to `plan`, applies
  the delay or the transport failure, and yields one `RequestLog` per request to a single `logStream`.
- **Persistence** — GRDB storage behind the `ProjectRepository` port; the app injects the port, not
  the concrete store. Journeys and steps are stored relationally, so a step can be reordered and
  diffed like any other row.
- **ControlPlane** — `ControlServer` (a loopback-only Vapor app), `ControlEndpointFile` (the `0600`
  discovery file), and `MimicControlService` + `MimicDaemon` (a windowless Mimic: store + engine +
  log + rules). `ControlHost` is the protocol both `MimicControlService` and the app's
  `AppControlHost` satisfy, so the HTTP layer does not know which it is serving — but in a shipped
  build it is always serving `AppControlHost`. See **[Two hosts, one shipped](#two-hosts-one-shipped)**
  before changing anything in this module.
- **SpecImport** — HAR/OpenAPI/Swagger parsing → `ImportCandidate`s. Linked by `AppFeatures` and by
  the `Mimic` app target (`Project.swift` declares it on both); neither `ControlPlane` nor
  `MimicCLICore` links it, in `Package.swift` or in `Project.swift`. That missing edge is the whole
  reason import has no command.
- **DesignSystem** — `DS*` tokens and components; SwiftUI only, no Domain coupling.
- **AppFeatures** — the only module that understands full user workflows. Coordination lives in:
  - `AppState` — the root `@Observable` for a session; coordinates endpoint/scenario/journey edits and
    import commits, and forwards server/project state. The single composition point.
  - `ProjectWorkspace` — project lifecycle, recents, autosave debounce.
  - `MockServerRuntime` — server lifecycle/config on `@MainActor`; drains the engine's `logStream` and
    mirrors the journey cursor for views.
  - `AppControlHost` — maps control commands onto the live session, so `mimic` drives the window.
- **MimicCLICore** — the `mimic` command surface as a library, so it is unit-testable. A client only.

## Two hosts, one shipped

The module map above is honest about what exists and misleading about what runs, so this needs saying
plainly: **`MimicDaemon` and `MimicControlService` are not reachable from any shipped path.**

`mimic daemon start` reads like the entry point to a separate headless process. It is not.
`DaemonCommand.Start` constructs an `AppCommand.Start`, sets `headless = true`, and calls its
`run()`. `AppLauncher.launch(headless:)` then puts `MIMIC_HEADLESS=1` into the child environment and
executes `Mimic.app/Contents/MacOS/Mimic` — the GUI bundle. Inside it, `HeadlessMode` sets the
activation policy to `.accessory` (no Dock icon, no window, but `NSApplication` still runs its event
loop, which the embedded servers need) and `ControlPlaneCoordinator` starts
`ControlServer(host: AppControlHost(…), mode: "headless")`. The `"headless"` reported by `mimic ping`
and written into the discovery file names a *mode of the app*. There is no second binary.

```bash
grep -rn MimicDaemon --include=*.swift .   # one hit: its own declaration
```

`MimicControlService` is referenced only by `MimicDaemon`, by doc comments, and by two test suites —
`Tests/ControlPlaneTests`, which exercises it as the product, and `Tests/MimicTests/HostParityTests`,
which drives it *beside* `AppControlHost` precisely to catch them drifting. Together the two source
files are about 636 lines that ship in the framework and never execute.

Three consequences worth understanding before you touch this area:

- **The two hosts are meant to answer identically, and only one is ever exercised by a user.** Two
  divergences were found by reading and fixed — a port passed to `server start` reached the runtime but
  was never written to the project, and `reset` answered with a different sentence than the headless
  service does; both are pinned in `Tests/MimicTests/AppStateAndViewTests.swift`. In both, the tests
  were right about the code they ran and wrong about the product.
  `Tests/MimicTests/HostParityTests` now drives commands through both hosts and pins four *live*
  differences as declared exceptions, each with the reason it is legitimate — the window's host answers
  project lifecycle optimistically because its store access is async, and the caller confirms with
  `state`. A difference that is written down is a contract; one that is not is a bug waiting to be
  found by a user.
- **The test coverage points the wrong way.** All 38 tests in `ControlPlaneTests` run against
  `MimicControlService`, directly or through `ControlServer` stood up on top of it.
  `AppControlHost` has 4 of its own in `Tests/MimicTests/AppStateAndViewTests.swift`, added only after
  those divergences shipped, plus the 13 in `HostParityTests` that drive it against its twin. A green
  `ControlPlaneTests` is still not evidence that `mimic` works.
- **The `CommandKind` discipline is still load-bearing.** Both hosts switch with no `default`, so a
  new command cannot compile until both handle it. That is what keeps `MimicControlService` from
  rotting into something that could no longer be wired up — the reason it is worth keeping in
  agreement even while it is dormant.

Whether to give `MimicDaemon` a real `mimic daemon` binary — which would let a headless Mimic run
without a GUI-capable app bundle, useful on a bare CI box — or to delete it and fold `ControlPlane`
down to the server and the discovery file, is an open architectural question. It is deliberately not
decided here. What this section exists to prevent is the previous state, where the docs described a
headless service as the thing CI runs and nothing said otherwise.

## Key decisions (the "why")

- **One implementation of the rules.** `ProjectCommandExecutor` applies every project-scoped operation
  as a pure transformation, and the CLI, the HTTP API, and the window all call it. Before this, adding
  an operation meant writing it twice; now the window and a script cannot disagree, by construction.
- **Operations are data.** Modelling an operation as a `ControlCommand` value buys determinism (it is
  replayable and diffable), a single interpreter, and self-description — an agent can ask a running
  instance what it accepts instead of trusting documentation.
- **Adding an operation is a compile error until it is routed.** A command carries associated values,
  so `ControlCommand` can never be `CaseIterable` — and without a way to enumerate the surface, every
  list claiming to mirror it is a copy maintained by hand. `CommandKind` is the join: no payloads, so
  it *is* `CaseIterable`, and `ControlCommand.kind` maps onto it through a switch with no `default`.
  The three switches that dispatch a command — the executor and both hosts — name every case for the
  same reason, so a new one stops the build in all three until somebody decides which side of the
  project-scoped line it falls on. The catalog is then checked against `allCases` rather than against
  a fourth hand-written list, which is what it used to be compared with: a copy of itself.
- **The journey cursor lives in an actor.** `MockRouteStore.resolve` reads the cursor, picks a step,
  and writes the advanced cursor back in one non-reentrant step. A read-then-write would let two
  concurrent requests consume the same step, which is exactly the bug a journey cannot afford.
- **Journeys overlay, they do not replace.** Unscripted requests fall through to endpoint resolution,
  so a journey only describes the steps that matter to the scenario under test. `notFound` is available
  when the opposite is wanted — making an unscripted call fail loudly.
- **Journey resolution is pure.** Keeping it out of the engine makes a flow testable as a table of
  requests in and responses out, with no sockets, and guarantees the served behaviour matches what the
  tests assert.
- **Deep modules over glue.** Coordination sits in a few `@Observable @MainActor` types; views stay
  declarative. Logic that the real bugs hide in is pulled into testable boundaries (`resolve`, `plan`,
  `ProjectCommandExecutor`), not into trivial per-call static forwarders.
- **One log channel.** The engine yields each request to a single bounded `AsyncStream`; the runtime
  drains it for the engine's lifetime (the stream is not finished on stop, so stop/start keeps
  delivering). No parallel callback path, no startup-log race.
- **Delays are real.** The effective delay is applied in the Vapor handler before responding; it is
  not a UI-only field. Global and per-endpoint (or per-step) delays are additive.
- **Transport failures are honest.** A drop is a torn-down chunked response — the closest a route
  handler gets to a dropped socket without reaching past Vapor into the NIO channel. A timeout sends
  nothing at all for its hold, so the client's own timer fires. Both are documented, including that a
  client may retry and each attempt is a new request to the journey.
- **The control plane is separate, loopback-only, and authenticated.** A separate Vapor app on a
  separate port, bound to `127.0.0.1`. Mixing an admin surface into the mock server would make Mimic's
  own routes indistinguishable from the mocks and would expose the control plane to the app under test.

  Loopback is *not* the access control, and it is worth being explicit because an earlier version
  treated it as if it were. On a developer's machine, binding `127.0.0.1` excludes the network and
  nothing else: every local process is already inside it, and a web page the developer visits can post
  to a loopback port. The access control is a per-instance token in a `0600` file, with `Origin` and
  `Host` checks on top to refuse browser-shaped requests. See [SECURITY.md](../SECURITY.md).
- **The CLI hosts nothing.** No server, no database, no Vapor, no GRDB — so it is a small static
  binary, and every invocation acts on the one live instance rather than a private copy of the world.
- **Test-only code is Debug-only.** XCUITest launch support (`UITestSupport`) is behind `#if DEBUG`
  so it never ships in Release.

## Conventions

- SwiftUI: `@Observable` (not `@StateObject`/`@ObservedObject`); modern `.alert(_:isPresented:…)`;
  `Task.sleep` (never `DispatchQueue.main.asyncAfter`); every interactive element has an
  `.accessibilityIdentifier()` + `.accessibilityLabel()`; perpetual animations honor Reduce Motion.
- Tests: Swift Testing (`@Test`/`#expect`) for units; XCTest + page objects for UI; accessibility-id
  targeting; `-MimicResetForTesting` + `MIMIC_DEFAULTS_SUITE` for isolation. Suites that bind a port
  (`MockServerEngineTests`, `ControlPlaneTests`) disable the sandbox via their own entitlements.
- Control API: additive changes only within `v1`; bump `ControlAPI.version` for a breaking change to
  the command or response shapes.
- Build/test commands: see [CONTRIBUTING.md](../CONTRIBUTING.md). All unit suites run via the
  `Mimic-Workspace` scheme; the portable modules also build and test with plain `swift test`.
