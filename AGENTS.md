# AGENTS.md

Guidance for AI assistants and contributors working in this repository. This is the single source
of truth; `CLAUDE.md` points here.

This file is deliberately short. It carries what is true on *every* task — what Mimic is, how to
build it, the module map, and the invariants that must never be broken — and routes everything else
to a skill under [`.agents/skills/`](.agents/skills/). The depth is not gone; it moved somewhere it
can be loaded when it is relevant instead of paid for on every turn. **Start at "Where the rules
live" and load the skill for what you are about to touch.**

## What is Mimic?

Mimic is a native macOS app for building and running local mock API servers: define endpoints,
configure responses, switch scenarios, script **journeys**, simulate latency and network failures,
and inspect live request traffic — so client work can start before the backend is ready. The embedded
Vapor server runs **in-process** (direct Swift calls, never HTTP-to-self).

Mimic is also drivable from a script. The `mimic` CLI and a loopback HTTP control API expose the
forty-seven operations in `CommandCatalog` — every project, server, endpoint, scenario, journey and
request-log operation — so a UI test or an AI agent can create configurations, script flows, and drive
a run without touching the interface.

**One workflow is window-only: spec import.** Turning a HAR capture or an OpenAPI/Swagger document
into endpoints has no `ControlCommand`, and neither `ControlPlane` nor `MimicCLICore` depends on
`SpecImport` — in `Package.swift` or in `Project.swift`. A script that wants a spec's routes parses
the file itself and issues `endpointCreate` + `scenarioUpdate` per route, which is what
`AppState.commitImportedCandidates` does once the review sheet is confirmed; only the *parse* and the
*review* are missing from the command surface. `mimic project import` is a different operation
entirely — it decodes a `MockProject`, the document `mimic project export` writes, and refuses
anything else with "is not a Mimic project document".

So: "every operation the window offers" is true of everything a project is made of, and false of
getting a spec into one. Do not restore the shorter, absolute claim.

Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the domain language and the reasoning
behind the module boundaries. Then [docs/JOURNEYS.md](docs/JOURNEYS.md) for the journey model,
[docs/CLI.md](docs/CLI.md) for the command surface, [docs/GRAPHQL.md](docs/GRAPHQL.md) for operation
matching, and [docs/ROADMAP.md](docs/ROADMAP.md) for what is deliberately not built yet.
[CONTRIBUTING.md](CONTRIBUTING.md) holds the build and test gates.

## Where the rules live

Nine skills, in `.agents/skills/`, symlinked into `.claude/skills/` so Claude Code and other agents
read one copy. **Load the skill before you touch its domain** — each one carries the failures that
motivated its rules, which is the part a generic skill cannot tell you.

| If you are about to… | Load |
|----------------------|------|
| Run or change a build, pick a `-scheme`, edit CI or a `Scripts/check_*` gate, chase a Linux-only failure | **mimic-build-and-test** |
| Write or review any view; pick a size, colour, weight or capitalization | **mimic-window-design** |
| Change a view or navigation; write or debug `MimicUITests`; touch test isolation | **mimic-ui-tests** |
| Add or change an operation, a CLI verb, or anything in the control plane | **mimic-control-surface** |
| Write SwiftUI | **swiftui-pro** |
| Write a unit or integration test | **swift-testing-pro** |
| Write `async`/`await`, an actor, a `Task`, or anything `Sendable` | **swift-concurrency-pro** |
| Run `tuist generate`, tag a target, or change a build config | **using-tuist-generated-projects** |
| Deepen a module or move a boundary | **improve-codebase-architecture** |

Several usually apply at once — a new view is `mimic-window-design` **and** `swiftui-pro`, and its
tests are `mimic-ui-tests`. Read a skill's `SKILL.md` first; it is a lightweight index that names
which of its `references/` files you actually need.

Four of these are repo-specific and were carved out of this file: `mimic-build-and-test`,
`mimic-window-design`, `mimic-ui-tests`, `mimic-control-surface`. `improve-codebase-architecture` is
vendored from `mattpocock/skills` and pinned in [`skills-lock.json`](skills-lock.json); the rest are
local.

There is no `xcuitest-pro` in this repository — `find . -iname '*xcuitest*'` returns nothing, and
this sentence is kept so nobody re-adds the reference believing it was an oversight. Agents run with
their own skill sets and some do carry one; if yours does, use it alongside `mimic-ui-tests`, which
is where this repo's hard-won XCUITest contract lives.

## Build & Test Commands

```bash
# Build (always use the workspace — Tuist resolves SPM deps into it)
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Debug build

# Every unit suite in one pass, through the aggregate Mimic-Workspace scheme.
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -skip-testing:MimicUITests

# A single unit suite, e.g. Domain:
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -only-testing:DomainTests

# UI tests:
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
  -destination 'platform=macOS' -only-testing:MimicUITests

# Release build gate (run after any SPM/Tuist change):
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Release CODE_SIGN_IDENTITY=- build

# Full suite + coverage refresh:
./Scripts/run_full_test_suite.sh

# Every gate CI runs, locally:
./Scripts/ci.sh

# CLI end-to-end (launches Mimic headless against a throwaway store — read the skill's caveats
# before running it):
./Scripts/run_cli_e2e.sh
```

After changing `Project.swift` or `Tuist/Package.swift`, run `tuist install && tuist generate`.

**Which scheme runs what, what each CI job covers, and what `run_cli_e2e.sh` needs before it can
find the CLI a gate just built** are in the **mimic-build-and-test** skill. Read it before editing a
workflow or concluding a scheme cannot test.

## Project Configuration

- **Platform:** macOS 26.0+
- **Swift:** 6.2 with `SWIFT_APPROACHABLE_CONCURRENCY = YES` everywhere, and
  `SWIFT_DEFAULT_ACTOR_ISOLATION` set **per target, not project-wide** — `MainActor` in the shared
  base, overridden to `"none"` by fourteen targets. Read the default as "MainActor when there is a
  window involved": the SwiftUI half is MainActor-by-default and the portable half is not. Which
  targets, why each override is load-bearing, and why Linux agrees only by coincidence are in
  **mimic-build-and-test**, `references/actor-isolation.md`.
- **Bundle ID:** `devxa.Mimic`
- **Sandbox:** App Sandbox and Hardened Runtime enabled (relaxed only where a test target requires it,
  and for the `mimic` command line tool, which launches and signals the app)
- **Project definition:** Tuist (`Project.swift`); modules use buildable folders

## Architecture

```
Mimic (app) → AppFeatures → Domain
                          → Persistence   → Domain
                          → MockServerEngine → Domain (+ Vapor)
                          → ControlPlane  → Domain (+ Vapor)
                          → SpecImport    → Domain
                          → DesignSystem  (SwiftUI only)

mimic (CLI) → MimicCLICore → Domain (+ ArgumentParser)
```

The map draws the import graph — who calls whom. The `Mimic` target's dependency list is wider
than its one drawn edge: `Project.swift` declares every module on the app target directly, because
the app is the composition root that bundles the frameworks it ships. The code under `App/Sources`
imports no module of this repository but `AppFeatures`; the extra links carry no calls.

- **Domain** — value types and pure rules (models, `RequestMatcher`, `JourneyResolver`,
  `MockResolver`, validation, and the `ControlCommand` language with its pure executor), plus
  `ControlEndpointDiscovery`, the read half of the discovery-file contract — file I/O and `kill(2)`
  liveness, the one deliberately impure corner, shared by the CLI and the control plane so the
  contract exists once. Foundation only.
- **MockServerEngine** — the embedded Vapor runtime; serves requests by asking Domain to resolve, and
  owns the live journey cursor.
- **Persistence** — GRDB storage behind the `ProjectRepository` port.
- **ControlPlane** — the automation surface: `ControlServer` (the loopback Vapor app),
  `ControlEndpointFile` (the `0600` discovery file), and the `ControlHost` protocol the server
  serves. The host itself is the app's. Depends on Domain and Vapor alone, and
  `Scripts/check_module_edges.py` fails the build if an edge onto Persistence or MockServerEngine
  reappears.
- **SpecImport** — HAR/OpenAPI/Swagger parsing into `ImportCandidate`s. Linked by `AppFeatures` and
  by the app bundle itself, and by nothing else: neither `ControlPlane` nor `MimicCLICore` depends on
  it, in either manifest, which is why spec import has no CLI or HTTP surface.
- **DesignSystem** — `DS*` SwiftUI tokens and components; no Domain coupling.
- **AppFeatures** — the only module that understands full user workflows (`AppState`,
  `ProjectWorkspace`, `MockServerRuntime`, `AppControlHost`, the journeys UI).
- **MimicCLICore** — the whole `mimic` command surface as a testable library. Depends on Domain and
  ArgumentParser only: the CLI is a **client, never a host**, so it links neither Vapor nor GRDB.

Key boundaries: Vapor runs embedded; business logic lives in Domain, not in views or Vapor routes;
persistence is injected as a port; the engine owns no long-term app state. Full detail in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### One implementation of the rules

Every operation that is a function of the open project — endpoints, scenarios, journeys, project
metadata — is applied by `ProjectCommandExecutor` in Domain, as

```swift
public static func apply(
    _ command: ControlCommand,
    to project: inout MockProject
) throws -> ProjectCommandOutcome?
```

The CLI, the HTTP control API, and the app window all call it. That return type is doing two jobs,
and a shorter spelling of it describes a different function: the Optional is the **decline** signal —
`nil` means "host-scoped, keep looking", not a failure, which is the partition the rest of this
document describes — and `ProjectCommandOutcome` pairs the `ControlResult` with `didMutate`, which is
how a host knows whether to persist and push to the engine rather than doing both after a read.

**When adding an operation, add a `ControlCommand` case and handle it in the executor.** Do not
implement it a second time in `AppState` or in a CLI command — a rule written twice is a rule that
will drift, and the window and the script would stop agreeing.

Only genuinely stateful operations belong outside the executor: server lifecycle, project selection,
the live journey cursor, and the request log.

### One host

`ControlHost` has exactly one production conformance: `AppControlHost` in `AppFeatures`. Every
`mimic` invocation and every HTTP control call reaches it, in a visible window and in headless mode
alike, because headless is a *mode of the app*, not a different process.

**Do not grow a second one.** `ControlPlane` carried one — `MimicControlService`, with a repository
and an engine of its own — and it was the mechanism behind every window/CLI divergence this
repository has shipped. The owner deleted it. `Scripts/check_module_edges.py` fails on an edge from
`ControlPlane` onto Persistence or MockServerEngine precisely because that is what a second host
looks like starting to regrow; if one is ever wanted, that is a decision to argue with the owner,
not a dependency to add in passing.

The full account — how headless resolves to the app bundle, what went with the deletion, and why
`ControlServerTests` is not evidence about the host — is in **mimic-control-surface**,
`references/one-host.md`.

## Definition of Done

Two checklists gate the work, and both live in skills because each is a hundred lines of hard-won
detail:

- **Changing a view or navigation** → **mimic-ui-tests**. Accessibility identifiers, XCUITests
  covering the changed flows, a passing suite, and test-only state kept out of production sources.
- **Adding or changing an operation** → **mimic-control-surface**. `ControlCommand` case,
  `CommandKind` case, `scope` classification, executor or host implementation, samples, catalog
  descriptor, CLI subcommand, exit codes.

Neither is optional and neither is fully compile-enforced. Load the skill rather than working from
memory of it.

## Non-negotiable patterns

**SwiftUI:** modern `.alert(_:isPresented:…)` (never the deprecated `Alert()` constructor);
`Task { try? await Task.sleep(for:) }` (never `DispatchQueue.main.asyncAfter`); every interactive
element gets `.accessibilityIdentifier()` and `.accessibilityLabel()`; `@Observable` for new code;
perpetual animations honor Reduce Motion.

**XCUITests:** page objects (no scattered raw queries); `.waitForExistence(timeout:)` (never
`sleep()`); accessibility-id targeting; configure state via launch environment, not UI; cover happy
path, error, empty, and edge cases.

**Swift concurrency:** Domain models are `Sendable`; use `actor` for shared mutable state; prefer
structured concurrency; all UI updates on `@MainActor`. State that a request mutates — the journey
cursor above all — must be read and written inside a single actor hop, never read-then-write.

**Unit tests:** Swift Testing for new units (`async throws`); XCTest only for UI.

**A test may never build its fixture with the function under test.** Write the fixture as literals.
A fixture derived from the mechanism moves *with* the mechanism, so reverting the mechanism leaves
the test green over the bug it was written for — the test cannot fail, and its passing is evidence
about nothing. `makeStubDatabase` in `MimicTests` is the case that cost this repository a wave: it
planted the WAL sidecars through the same `UITestSupport.sidecarURLs` the reset deletes through, so
reverting `sidecarURLs` to its old `appendingPathExtension` form moved the fixture and the assertion
together and the reset test stayed green while every real `-wal` survived the reset. It shipped under
a comment defending the self-reference, with the causality backwards.

The check is one question, and it is worth asking of every test you write: **if I revert the
mechanism this test is for, does this test go red?** If the fixture comes from the mechanism, the
answer is no. Two habits follow — pin the literal values the mechanism is supposed to produce in a
test of their own (`sidecarNamesAreTheOnesSQLiteWrites`), and, where a checker is a script rather
than a type, give it a `--self-test` over invented inputs that never asks the functions under test
what the right answer is (`check_house_rules.sh --self-test`, `check_doc_counts.py --self-test`).
Negative controls are worth labelling as such in the test's own comment, so a later reader does not
mistake a test that is green by construction for one that is guarding something.

**Visual:** sentence case inside the window, Title Case in the menu bar; every interactive control
answers the pointer; sizes come from the `DS*` ladders, never from a literal. The reasoning, the
exceptions and the layout traps are in **mimic-window-design**.

**The control plane never binds beyond `127.0.0.1`**, and the discovery file is a credential —
`0600`, and its token goes only to the instance that advertised it. See **mimic-control-surface**,
`references/loopback-security.md`, before touching any of it.

Several of these are enforced mechanically by `Scripts/check_house_rules.sh`, which cites the skill
that explains each rule when it fails.
