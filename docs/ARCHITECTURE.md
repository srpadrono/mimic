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
workflow that is not a command is **spec import**: `SpecImport` is linked by `AppFeatures` and by the
app bundle, and by nothing else — neither `ControlPlane` nor `MimicCLICore` depends on it, in either
manifest — so turning a HAR or an OpenAPI document into endpoints happens in the window and nowhere
else. A script parses the file itself and issues `endpointCreate` + `scenarioUpdate` per route —
which is precisely what `AppState.commitImportedCandidates` does after the review sheet is confirmed,
so the rules applied are the same either way.

That sentence used to read "linked by `AppFeatures` alone", which the app target's own dependency
list contradicts, and it was checked by nobody: [`Scripts/check_module_edges.py`](../Scripts/check_module_edges.py)
now reads both manifests on every CI run and fails if `ControlPlane` or the CLI can reach
`SpecImport` by any path, so this paragraph and the five others like it — in AGENTS.md, README.md,
[CLI.md](CLI.md), [GRAPHQL.md](GRAPHQL.md) and [ROADMAP.md](ROADMAP.md) — cannot quietly stop being
true.

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
                          → ControlPlane     → Domain (+ Vapor)
                          → SpecImport       → Domain
                          → DesignSystem     (SwiftUI only)

mimic (CLI) → MimicCLICore → Domain (+ ArgumentParser)
```

The map draws the import graph — who calls whom. The `Mimic` target's dependency list is wider than
its one drawn edge: `Project.swift` declares every module on the app target directly, because the
app is the composition root that bundles the frameworks it ships. The code under `App/Sources`
imports no module of this repository but `AppFeatures` (plus the system frameworks); the extra
links carry no calls.

- **Domain** — value types + pure rules. Imports Foundation only. No SwiftUI/Vapor/GRDB. Holds:
  - models, `RequestMatcher`/`resolve`, validation
  - `JourneyResolver` / `JourneyRunState` / `MockResolver` — journey resolution as a pure function
  - `ControlCommand` / `ProjectCommandExecutor` — the command language and its pure interpreter
  - `CommandCatalog` — runtime self-description; `JourneyTemplates` — the built-in journey library
  - `ControlEndpointDiscovery` — the read half of the control-plane discovery-file contract (file
    I/O and `kill(2)` liveness — the one deliberately impure corner, shared by the CLI and the
    control plane so the contract exists once)
- **MockServerEngine** — `MockServerEngine` actor owns the Vapor app + a `MockRouteStore` snapshot of
  the live configuration *and the journey cursor*; serves requests by asking Domain to `plan`, applies
  the delay or the transport failure, and yields one `RequestLog` per request to a single `logStream`.
- **Persistence** — GRDB storage behind the `ProjectRepository` port; the app injects the port, not
  the concrete store. Journeys and steps are stored relationally, so a step can be reordered and
  diffed like any other row. `load` now **refuses a row written by a newer build**: the stored
  `schemaVersion` is checked before a single field is read, and a document from ahead of this one
  throws `PersistenceError.unsupportedSchemaVersion` naming both numbers, because the fields this
  build does not know about are exactly the ones a partial read would drop. `allProjects` is
  deliberately *not* filtered — a project you cannot open is still a project you have, and hiding it
  would look exactly like "the recents list is empty". The host maps `PersistenceError` to
  `persistence.failure` with that message, so `mimic project open` prints it.

  Two things this does not do. It does not carry the stored number into the value: `toDomain()`
  rebuilds through `MockProject`'s memberwise initialiser, which stamps `currentSchemaVersion`, and
  changing that needs a `schemaVersion:` parameter in Domain. On the `load` path that is a real
  forward migration rather than a relabelling — nothing from ahead of this build gets past the guard,
  and a row from behind it genuinely is the current shape once loaded. The window's reaction is
  fixed separately: `ProjectWorkspace.openProject(id:)` strikes the recents entry only for
  `PersistenceError.projectNotFound` and reports every other load failure — a newer-schema document
  included — on `autosaveStatus`, keeping the entry and `lastOpenedProjectID`.
- **ControlPlane** — `ControlServer` (a loopback-only Vapor app), `ControlEndpointFile` (the `0600`
  discovery file), and `ControlHost`, the protocol the server serves so the HTTP layer does not know
  who is answering. In production the answerer is always the app's `AppControlHost`. The module
  depends on Domain and Vapor alone — see **[One host](#one-host)** for the windowless second host
  it used to carry and why the owner deleted it.
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

## One host

`mimic daemon start` reads like the entry point to a separate headless process. It is not.
`DaemonCommand.Start` constructs an `AppCommand.Start`, sets `headless = true`, and calls its
`run()`. `AppLauncher.launch(headless:)` then puts `MIMIC_HEADLESS=1` into the child environment and
executes `Mimic.app/Contents/MacOS/Mimic` — the app bundle. Inside it, `HeadlessMode` sets the
activation policy to `.accessory` (no Dock icon, no window, but `NSApplication` still runs its event
loop, which the embedded servers need) and `ControlPlaneCoordinator` starts
`ControlServer(host: AppControlHost(…), mode: "headless")`. The `"headless"` reported by `mimic ping`
and written into the discovery file names a *mode of the app*. There is no second binary, and — as
of the owner's decision recorded here — no second host either.

There used to be one. `ControlPlane` carried `MimicControlService` + `MimicDaemon`, a windowless
Mimic with a store, an engine and command handling of its own, reachable from no shipped path: the
host every `mimic` invocation actually hit was `AppControlHost`, while every host-level test in
`ControlPlaneTests` exercised the service — so the better-tested host was the dead one, and a green
`ControlPlaneTests` was evidence about code no user runs. Four behavioural divergences between the
two shipped before a parity suite existed to catch them. Faced with wiring the daemon to a real
binary or deleting it, the owner chose deletion: headless-as-a-mode covers what a daemon was for,
and one implementation of every rule is worth more than a second binary. The git history keeps both
files if that trade is ever revisited.

What enforces the new shape:

- **The module edge is a CI gate.** `ControlPlane` depends on Domain and Vapor alone;
  `Scripts/check_module_edges.py` fails on an edge onto Persistence or MockServerEngine from it,
  because a store or an engine under `ControlPlane` is a second host regrowing.
- **The sweeps drive the shipped host.** `Tests/MimicTests/HostCommandSweepTests.swift` walks every
  host-scoped `CommandKind` through `AppControlHost`, with and without a project open, and fails if
  any answers from the unimplemented arm; its sample list is a `default`-free switch over
  `CommandKind`, so the *build* breaks until a new command has a payload to sweep with. The answers
  that used to be parity-compared against the second host are pinned to their literal values there,
  which is the stronger claim — two hosts could drift together, a literal cannot.
- **`ControlServerTests` tests the HTTP layer.** It stands `ControlServer` on `LoopbackTestHost`, a
  fixture that routes project-scoped commands through the production executor and answers a handful
  of host-scoped arms with session glue built from the same Domain pieces (`HostReport`,
  `ControlMessages`, `EndpointValidator`). Host behaviour is `MimicTests`' to cover, directly.

## Key decisions (the "why")

- **One implementation of the rules.** `ProjectCommandExecutor` applies every project-scoped operation
  as a pure transformation, and the CLI, the HTTP API, and the window all call it. Before this, adding
  an operation meant writing it twice; now the window and a script cannot disagree, by construction.
- **Operations are data.** Modelling an operation as a `ControlCommand` value buys determinism (it is
  replayable and diffable), a single interpreter, and self-description — an agent can ask a running
  instance what it accepts instead of trusting documentation.
- **Adding an operation is a compile error until it is *classified*, and a test failure until it is
  routed.** A command carries associated values, so `ControlCommand` can never be `CaseIterable` —
  and without a way to enumerate the surface, every list claiming to mirror it is a copy maintained
  by hand. `CommandKind` is the join: no payloads, so it *is* `CaseIterable`. Two switches over it
  have no `default:` and are the compile-time half — `ControlCommand.kind`, which forces a new case
  to be named, and `CommandKind.scope`, which forces it onto one side of the project/host line.

  The switches that *dispatch* a command — `ProjectCommandExecutor.apply` and the host's
  `AppControlHost.perform` — each end in a `default:` instead, because each is a switch over
  `ControlCommand` while its caller has already narrowed by `CommandKind`, and the compiler cannot
  see that narrowing; closing them would restore the hand-written case lists that `scope` was
  introduced to collapse into one. Each tail throws and names the command rather than falling
  through to a plausible lie like "no project is open".

  What replaces the compile check is a set of sweeps over `allCases`, one per surface. `DomainTests`
  puts a sample of every kind through `apply` from both sides, so a project-scoped command reaching
  the executor's tail — or a host-scoped one being swallowed there — fails. `HostCommandSweepTests`
  does the same through the host, with and without a project open, asserting it never answered from
  its unimplemented arm; its sample list is a `default`-free switch over `CommandKind`, so a new
  command stops that target compiling until it is covered. `ControlTransportTests` requires some
  `mimic` invocation to emit every kind. And the catalog is checked against `allCases` rather than
  against a fourth hand-written list, which is what it used to be compared with: a copy of itself.
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
  (`MockServerEngineTests`, `ControlPlaneTests`, `MimicTests`) all bind loopback: the first two
  disable the sandbox via entitlements of their own, while `MimicTests` declares none and takes port
  `0` for its one socket — `ComposedControlServerTests`, which stands `ControlServer` on
  `AppControlHost`. `Scripts/check_doc_counts.py` recomputes that list from the tree, because an
  enumeration presented as complete is the claim this repository keeps getting wrong.
- Control API: additive changes only within `v1`; bump `ControlAPI.version` for a breaking change to
  the command or response shapes.
- Build/test commands: see [CONTRIBUTING.md](../CONTRIBUTING.md). All unit suites run via the
  `Mimic-Workspace` scheme; the portable modules also build and test with plain `swift test`.
