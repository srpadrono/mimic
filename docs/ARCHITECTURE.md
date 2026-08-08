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

It is also a testing platform: everything the window does is available as a command, so UI tests,
integration tests, and AI agents can reproduce a whole application scenario without driving the UI.

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
  - `RequestLogFilter` — the request log's filter predicate. In Domain rather than in the drawer that
    draws it, so the window and `mimic log list` narrow traffic by one rule instead of two. It carries
    `endpointID`, which the CLI does not yet expose; see the known gap in [ROADMAP.md](ROADMAP.md).
  - `EndpointFromLog` — turns a logged request into a draft `Endpoint`, so "I saw this call go
    unanswered" becomes a configured mock without retyping the path

  Two types the redesign planned and did not build: `RequestLogStatistics` and `TrafficWindow`
  belonged to the server segment's traffic sparkline, which needs a ≤4Hz ticker running whether or not
  anyone is watching. It was deferred rather than deleted — see [ROADMAP.md](ROADMAP.md) — and the
  types went with it. Nothing else was written against them.
- **MockServerEngine** — `MockServerEngine` actor owns the Vapor app + a `MockRouteStore` snapshot of
  the live configuration *and the journey cursor*; serves requests by asking Domain to `plan`, applies
  the delay or the transport failure, and yields one `RequestLog` per request to a single `logStream`.
- **Persistence** — GRDB storage behind the `ProjectRepository` port; the app injects the port, not
  the concrete store. Journeys and steps are stored relationally, so a step can be reordered and
  diffed like any other row.
- **ControlPlane** — `MimicControlService` (a windowless Mimic: store + engine + log + rules) and
  `ControlServer` (a loopback-only Vapor app exposing it). `ControlHost` is the protocol both it and
  the app's `AppControlHost` satisfy, so the HTTP layer does not know which it is serving.
- **SpecImport** — HAR/OpenAPI/Swagger parsing → `ImportCandidate`s.
- **DesignSystem** — `DS*` tokens and components; SwiftUI only, no Domain coupling.
- **AppFeatures** — the only module that understands full user workflows. Coordination lives in:
  - `AppState` — the root `@Observable` for a session; coordinates endpoint/scenario/journey edits and
    import commits, and forwards server/project state. The single composition point.
  - `ProjectWorkspace` — project lifecycle, recents, autosave debounce.
  - `MockServerRuntime` — server lifecycle/config on `@MainActor`; drains the engine's `logStream` and
    mirrors the journey cursor for views.
  - `AppControlHost` — maps control commands onto the live session, so `mimic` drives the window.
- **MimicCLICore** — the `mimic` command surface as a library, so it is unit-testable. A client only.

## Key decisions (the "why")

- **One implementation of the rules.** `ProjectCommandExecutor` applies every project-scoped operation
  as a pure transformation, and the CLI, the HTTP API, and the window all call it. Before this, adding
  an operation meant writing it twice; now the window and a script cannot disagree, by construction.
- **Operations are data.** Modelling an operation as a `ControlCommand` value buys determinism (it is
  replayable and diffable), a single interpreter, and self-description — an agent can ask a running
  instance what it accepts instead of trusting documentation.
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

## Window geometry

The three panes are `NSSplitViewItem`s, and their floors are constraints AppKit enforces rather than
numbers a view recomputes. Two of them are load-bearing on the *content* above them, so they are
recorded here rather than left in `PanelLayoutStore`:

| Bound | Value | Why that number |
|---|---|---|
| Minimum window content width | 1140 | Two constraints converge: the request log's header is 394pt of incompressible controls plus a filter field with a 160pt floor, and its row carries 380pt of fixed columns plus a 180pt minimum path. Both are measured SF Pro/SF Mono advances, not estimates. |
| `minimumInspectorWidth` | 260 | The inspector's three-mode rail measures 256.7pt at 12pt semibold. At the previous 220 it overflowed on the first inward drag, and an over-committed `HStack` in this window pushes its *leading* edge out of view rather than truncating. |
| Navigator default | 300 | Its trailing slot is capped at 60pt for the same reason: at 90 the path column truncates on ordinary routes like `/api/v1/orders/{id}`. |

A raised floor strands anyone whose persisted width sits below it, so `PanelLayoutStore` clamps on
read rather than honouring a stored value it no longer allows.

**Column yield order in the request log is Scenario → Answered by → Time.** Method and Path never
yield. Surplus from a hidden panel goes to Path, since it is the only column whose content is
unbounded.

## Material

macOS 26 gives the toolbar and a sidebar split item its system material on recompile, whether or not
the app opts in. So the decision is not whether to adopt it but which surfaces to let it own:

- **Material** — the window toolbar, and the navigator.
- **Opaque** — the centre editor, the request log, and the inspector body. These are where a payload
  is read, and a translucent surface under 11pt monospaced text is a legibility cost with no
  compensating gain.

This is what Xcode does, and it is the position the design handoff's own Liquid Glass notes reach.

One consequence worth stating because it changes what a test can assert: a contrast ratio computed
against the navigator's background is an approximation against the material's substrate, not a
measurement. `ContrastTests` records that assumption for those pairings instead of pinning a number.

Full reasoning, and the questions this replaced, in
[docs/redesign/decisions.md](redesign/decisions.md).
