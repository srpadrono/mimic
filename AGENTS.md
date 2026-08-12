# AGENTS.md

Guidance for AI assistants and contributors working in this repository. This is the single source
of truth; `CLAUDE.md` points here.

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

# CLI end-to-end (launches Mimic headless against a throwaway store — read the caveats below
# before running it):
./Scripts/run_cli_e2e.sh
```

After changing `Project.swift` or `Tuist/Package.swift`, run `tuist install && tuist generate`.

### Which scheme runs what

`Project.swift` declares **exactly one** scheme — confirm with `grep -c '\.scheme(' Project.swift`,
which answers `1`, for the `Mimic` scheme at the bottom of the file. Every other name you will see
passed to `-scheme` in this repository (`Mimic-Workspace`, `Domain`, `MockServerEngine`,
`Persistence`, `ControlPlane`, `MimicCLICore`, `DesignSystem`, `SpecImport`) is **inferred by Tuist**
at generation time, not written by anyone here.

This section used to say the per-module schemes "build the frameworks but do not bundle their test
targets", and that is why `Mimic-Workspace` was presented as the only way to run a unit suite. It
cannot be right: [`Scripts/run_full_test_suite.sh`](Scripts/run_full_test_suite.sh) — the sole
producer of the coverage numbers — runs `xcodebuild -scheme Domain test` and six more against exactly
those schemes, and `Scripts/update_readme_coverage.py` then reads the `Domain.xcresult`,
`ControlPlane.xcresult` … bundles they leave behind. A scheme with nothing testable in it fails
immediately with *"Scheme X is not currently configured for the test action"* and produces no bundle,
so seven of that script's steps would be dead on arrival and it could never produce the coverage
section it is written to produce. Tuist's inferred schemes group a target with the suites whose names
extend it, and every test target here is named `<Module>Tests` for exactly that reason.

So: `Mimic-Workspace` is the scheme to reach for because it builds and tests **everything** in one
pass, not because the per-module ones cannot test. Prefer the smallest scheme that contains the suite
you are iterating on — it compiles less. Neither claim can be checked from inside this file; the
generated workspace is the authority, and it answers in one command:

```bash
xcodebuild -workspace Mimic.xcworkspace -list      # every scheme Tuist actually generated
```

### What CI actually covers

CI runs on every pull request and on every push to `main`, in two jobs split by what actually needs a
Mac. Both are free: GitHub does not meter standard hosted runners on public repositories, macOS
included.

**Linux** builds through [`Package.swift`](Package.swift) rather than Tuist — the domain rules, mock
engine, persistence, control plane, spec import and CLI are plain Swift, so most of the suite reports
back in a couple of minutes. Both manifests declare those modules from the same directories, so they
cannot drift in what they compile, only in how targets are declared. What they *can* drift in is
dependency resolution: they resolve the same ranges into two separate lockfiles, and 21 packages —
Vapor, NIO and GRDB among them — had already diverged, so this job was passing against versions the
shipped `.pkg` does not contain. The Linux job now checks `Package.resolved` against
`Tuist/Package.resolved` before it builds. Compiler settings are the other half, and the job now
reports on them too — as a *warning*, not a failure: `Project.swift` sets
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` and `Package.swift` sets nothing, so Linux still
accepts an implicit transitive import that Xcode rejects. Enabling the flag on the SwiftPM side is the
fix; it warns rather than fails because turning it on will surface real errors, and going red before
anyone can iterate on them helps nobody. The gap is visible and tracked instead of silent.

**macOS** (`macos-26`) covers everything that needs Xcode: `tuist generate`, the Debug build, the
app-level suites, **the XCUITest suite**, and the Release gate. The image label is load-bearing —
macOS 26 and Swift 6.2 are the compile floor, not a preference.

Two things about the macOS job are worth knowing before you edit it:

- **`sudo automationmodetool enable-automationmode-without-authentication` is what makes XCUITest
  possible at all.** Since Monterey, macOS asks a human to approve UI automation before a runner may
  drive another app. Nobody is at the keyboard on CI, so without it the runner fails to initialise
  and reports `Timed out while enabling automation mode` with *zero tests executed* — which reads
  like a broken suite rather than a missing permission. The same message appears locally when the
  SIP-protected `automationmode-writer` service wedges; see the note in the UI test section.
- **Everything is signed ad-hoc (`CODE_SIGN_IDENTITY=-`).** The project carries a `DEVELOPMENT_TEAM`
  for local builds, and a hosted runner has none of that team's certificates. It does not need them:
  a macOS app only has to be signed *somehow* to launch.

This was not always possible. While the repo was private, every run died in about two seconds with
zero steps executed, on Linux and macOS alike, because of a billing block — which is why the triggers
used to be commented out and the macOS job disabled. Making the repo public resolved it.

`./Scripts/ci.sh` runs the same gates locally and is still the fastest way to check before pushing:
lockfiles, compiler settings, `swift test`, `tuist install && generate`, the Debug build, every unit
suite, the Release gate, the UI suite, `check_house_rules.sh --self-test` followed by the real house
rules scan, and `check_doc_counts.py`. Its own header names the three things it cannot reproduce —
`swift test` runs on this machine's toolchain rather than in the `swift:6.2` container, the UI suite
runs without CI's `-retry-tests-on-failure`, and runner setup is absent — so read it rather than
treating a green local run as a green CI run.

### `run_cli_e2e.sh`: what it needs, and why no gate runs it

It covers a seam nothing else does — process launch, discovery file, real sockets — and `ci.sh`
still does not run it. That is deliberate and the reason is written into both `ci.sh` and
`.github/workflows/ci.yml`: **it cannot find the CLI those gates just built.** No `xcodebuild` step
in either passes `-derivedDataPath`, so the products land in DerivedData outside the checkout while
the script looks for `*Build/Products*` *inside* it, then falls back to whatever `mimic` is on
`PATH` — an installed build, not this one. `AppLauncher.resolveExecutable` picks the *app* the same
way, independently (`MIMIC_APP_PATH`, `/Applications/Mimic.app`, `~/Applications/Mimic.app`), so
wiring it up means exporting two paths, both pointing at what the run just built. A green e2e against
an installed build says nothing about the working tree.

What it is no longer is dangerous, and that is a recent change worth knowing because the old
behaviour is what kept it out of the docs' recommended path:

- **It stops the instance it launched, by pid.** The cleanup trap used to call `mimic app stop`,
  which reads the *shared* `control.json` and signals whatever pid it names — so on a machine with
  Mimic open, running this script quit the developer's own instance, on every exit path including
  the ones where it had launched nothing. The pid now comes out of what `mimic app start` printed
  about the process it launched.
- **It needs `MIMIC_CONTROL_FILE`, and it exports it** (`"$WORK/control.json"`). That variable is
  read by `ControlEndpointFile.writeURL` and `searchURLs` in `ControlPlane`, and the override
  *replaces* the search list instead of joining the front of it, so this run cannot fall through to
  a developer's real instance. The script asserts the file exists after launch, because the app —
  not the script — is what honours the variable, and if it is missing the instance advertised itself
  at the shared path after all.
- `set -euo pipefail` is now on, so a line added without a trailing `|| fail` cannot pass silently.

**The CLI half of that variable is not implemented.** `MimicCLICore`'s own discovery reader — a
second copy, because the CLI links no `ControlPlane` — still searches only the two Application
Support paths (`grep -n MIMIC_CONTROL_FILE Sources/MimicCLICore/*.swift` returns nothing).

**So an isolated run has to supply the token, not only the destination.** This paragraph used to say
the script was "unaffected only because it also exports `MIMIC_CONTROL_URL` and `MIMIC_CONTROL_PORT`,
which win in `resolveBaseURL` before discovery is consulted", and that is half an answer: those two
resolve *where* to send a command and carry no credential — `resolveToken` never consults either.
Move the file and `mimic` finds no `control.json` at all, so it sends no `X-Mimic-Token`, and
`ControlServer.denial` guards every route including `/health`; every command comes back 401 while
`mimic app start` still looks fine, because `isReachable` accepts a 401 as proof something answered.
`Scripts/run_cli_e2e.sh` therefore exports `MIMIC_CONTROL_TOKEN` as well, which `ControlServer.init`
takes for the token it demands and `ControlEndpointFileReader.resolveToken` takes first for the one
it sends. Anything else wanting an isolated run needs all four, and mirroring `MIMIC_CONTROL_FILE`
into `MimicCLICore` — which would reduce that to two — is an open item.

When touching anything the Linux build compiles, remember it is not macOS: `URLSession` lives in
`FoundationNetworking`, the BSD socket calls live in `Glibc` rather than `Darwin`, and some C types
are wider there. `Tests/MockServerEngineTests/PlatformSockets.swift` keeps those differences in one
place — verify with `docker run --rm -v "$PWD":/src -w /src swift:6.2 …` rather than guessing.

### Testing against real inputs

Three shipped bugs came from fixtures that were tidier than reality: a replayed
`Content-Encoding: gzip` broke every real HAR import, an appended `Content-Type` was emitted twice,
and every Swagger fixture in the suite declared `produces` inside the operation while real specs
overwhelmingly declare it once at the document level — which the parser did not read, so those specs
imported as plain text and, because `.plainText` short-circuits the JSON body fallback, with no body
either. Two bugs behind one convention every fixture happened to share.

When adding a feature that consumes external input, add a case built from something a real server,
browser or spec generator produces. `Tests/SpecImportTests/RealCaptureTests.swift` and
`Tests/MockServerEngineTests/RealTrafficTests.swift` are the homes for HAR and traffic; the
OpenAPI/Swagger shape cases sit beside their parser in `Tests/SpecImportTests/OpenAPIParserTests.swift`.

The tell is a fixture whose every instance agrees on something the format does not require. If all of
them put a field in the same place, the parser has only ever been asked to read it there.

## Project Configuration

- **Platform:** macOS 26.0+
- **Swift:** 6.2 with `SWIFT_APPROACHABLE_CONCURRENCY = YES` everywhere, and
  `SWIFT_DEFAULT_ACTOR_ISOLATION` set **per target, not project-wide**. The shared base in
  `Project.swift` sets it to `MainActor`, and fourteen targets then override it to `"none"`:
  `Domain`, `MockServerEngine`, `Persistence`, `ControlPlane`, `MimicCLICore`, `SpecImport`, the
  `MimicCLI` tool, each of their six test targets, and `MimicUITests`. Only five targets actually
  compile under `MainActor` — `DesignSystem`, `DesignSystemTests`, `AppFeatures`, the `Mimic` app,
  and `MimicTests` — which is to say: **the SwiftUI half is MainActor-by-default and the portable
  half is not.**

  The overrides are not incidental. Each one is a place where main-actor inference would be wrong
  rather than merely unnecessary, and `Project.swift` says which above each target: MainActor on
  `Domain`'s struct inits would stop nonisolated modules constructing Domain values at all; the
  engine lives on NIO threads; GRDB's closures run off the main queue and deadlock against
  `DatabaseQueue`; `SpecImport` is called from `Task.detached`; and `XCTestCase`'s lifecycle methods
  are nonisolated, so `MimicUITests` cannot compile with it. Read the default as "MainActor when
  there is a window involved".

  `Package.swift` sets no `defaultIsolation` at all, so on Linux the portable modules take the
  language default — nonisolated — which happens to be what the fourteen `"none"` overrides ask for.
  The two agree today by coincidence, not by construction, and nothing checks that they still will:
  the same unchecked-compiler-settings gap the CI section notes for
  `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`. Changing the base setting in `Project.swift`
  would not move Linux with it.
- **Bundle ID:** `devxa.Mimic`
- **Sandbox:** App Sandbox and Hardened Runtime enabled (relaxed only where a test target requires it,
  and for the `mimic` command line tool, which launches and signals the app)
- **Project definition:** Tuist (`Project.swift`); modules use buildable folders

## Architecture

```
Mimic (app) → AppFeatures → Domain
                          → Persistence   → Domain
                          → MockServerEngine → Domain (+ Vapor)
                          → ControlPlane  → Domain, Persistence, MockServerEngine (+ Vapor)
                          → SpecImport    → Domain
                          → DesignSystem  (SwiftUI only)

mimic (CLI) → MimicCLICore → Domain (+ ArgumentParser)
```

- **Domain** — value types and pure rules (models, `RequestMatcher`, `JourneyResolver`,
  `MockResolver`, validation, and the `ControlCommand` language with its pure executor).
  Foundation only.
- **MockServerEngine** — the embedded Vapor runtime; serves requests by asking Domain to resolve, and
  owns the live journey cursor.
- **Persistence** — GRDB storage behind the `ProjectRepository` port.
- **ControlPlane** — the automation surface. `ControlServer` (the loopback Vapor app) and
  `ControlEndpointFile` (the `0600` discovery file) are what ships; `MimicControlService` and
  `MimicDaemon`, the windowless composition root beside them, are **not reachable in production** —
  see "Two hosts, one of them shipped" below before touching either.
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
`(ControlCommand, inout MockProject) -> ControlResult`. The CLI, the HTTP control API, and the app
window all call it.

**When adding an operation, add a `ControlCommand` case and handle it in the executor.** Do not
implement it a second time in `AppState` or in a CLI command — a rule written twice is a rule that
will drift, and the window and the script would stop agreeing.

Only genuinely stateful operations belong outside the executor: server lifecycle, project selection,
the live journey cursor, and the request log.

### Two hosts, one of them shipped — a known issue

`ControlHost` has two conformances: `AppControlHost` in `AppFeatures`, which maps commands onto the
live session, and `MimicControlService` in `ControlPlane`, which owns a repository and an engine of
its own. Read from the outside, the second looks like the one CI uses. **It is not. Nothing in
production constructs it.**

Follow `mimic daemon start` and it ends up in the same place `mimic app start` does.
`DaemonCommand.Start` builds an `AppCommand.Start`, sets `headless = true` on it, and calls its
`run()`. That reaches `AppLauncher.launch(headless: true)`, which sets `MIMIC_HEADLESS=1` in the
child environment and executes `Mimic.app/Contents/MacOS/Mimic` — the app bundle, not a separate
daemon binary. Inside it, `HeadlessMode` drops the activation policy to `.accessory` and
`ControlPlaneCoordinator.start` stands up `ControlServer(host: AppControlHost(…), mode: "headless")`.
The `"headless"` in the discovery file and in `mimic ping`'s reply names a *mode of the app*, not a
different process. Confirm it in one command:

```bash
# Nothing outside the file names the type. Prints nothing; exits 1.
grep -rn MimicDaemon --include=*.swift . | grep -v '^\./Sources/ControlPlane/MimicDaemon\.swift:'
```

The unfiltered `grep -rn MimicDaemon --include=*.swift .` that this replaced was documented here and
in README.md as returning "one hit, its own declaration". It returns **two**: the declaration, and a
doc comment a few lines above it that quotes the grep. A check whose result its own documentation
moves is not a check; filter the file out, as above, and what is left is the fact being claimed.

`MimicControlService` fares no better — outside its own file, every reference is a doc comment, a
test, or `MimicDaemon`, which is itself unreachable. Both files ship in the framework and never
execute, while `ControlServer.swift` and `ControlEndpointFile.swift` beside them are load-bearing.
(There used to be a line count here. It is gone on purpose: it changes whenever anybody edits a
comment in either file, so it was guaranteed to drift, and `wc -l` answers it on demand.)

**This is the mechanism behind every divergence between the two hosts, and it works in the worst
direction: the unreachable host is the better-tested one.** `Tests/ControlPlaneTests` holds two
files, and every test in them that exercises a *host* runs against `MimicControlService`:
`ControlServiceTests` builds one directly, and `ControlServerTests` stands a `ControlServer` on top of
one. (`ControlServerTests` also carries an `Endpoint discovery` suite and a Host-header unit test
that stand up no host at all, several of them added by the same work that widened
`ControlEndpointFile` — so "every test in both" was true when it was written and is not now.) `AppControlHost`, the host
every `mimic` invocation actually reaches, has a handful of its own in
`Tests/MimicTests/AppStateAndViewTests.swift` plus `Tests/MimicTests/HostParityTests.swift`, which
drives both hosts together — all added after the fact. (Counts are left out deliberately; these
suites are edited often and a number here would be wrong within the week. `grep -c '@Test'` answers
it.) The comment above the `AppControlHost` cases in `AppStateAndViewTests.swift` records that
it "had no unit test anywhere in the repo, which is how the four divergences between it and
`MimicControlService` shipped unnoticed". A green ControlPlane suite is evidence about code the user
never runs.

Two things follow for anyone working here:

- **Do not delete either file.** Wiring `MimicDaemon` up to a real `mimic daemon` binary and deleting
  it are both defensible, and choosing between them is an architectural decision for a human —
  it turns on whether a headless Mimic should keep needing a GUI-capable app bundle. What is not
  defensible is documentation that hides the fact that the decision is pending, which is why this
  section exists.
- **When you add a command, the tests that matter are the `AppControlHost` ones.** The *compiler*
  does not force you to implement it in either host — both dispatch switches end in a `default:` that
  throws at runtime (see the CLI/control-plane Definition of Done below for exactly what is and is
  not compile-checked). `HostParityTests` is what forces it: its two sweeps drive every host-scoped
  kind through both hosts and fail if either answers from that arm. Implement both, and read a green
  `ControlPlaneTests` for what it is — evidence about code the user never runs.

## Visual standard

The window is measured against Xcode. Not as a style preference — Xcode is the app this one sits
beside all day, and a mock server that looks like a different generation of software next to it reads
as unfinished. When something here is ambiguous, open Xcode and look at how it solves the same
problem.

- **Sentence case inside the window; Title Case in the menu bar.** "Response headers", never
  "RESPONSE HEADERS"; "New scenario", never "New Scenario". No `.textCase(.uppercase)` in the
  codebase. Two exceptions, both deliberate:
  - `DSMethodBadge` — `GET` and `POST` are uppercase tokens, not shouted prose.
  - **The menu bar.** `MimicScene`'s `CommandMenu` items are Title Case, and that is correct.
    Apple's HIG specifies title-style capitalization for menu items, and Xcode does exactly that —
    its View menu reads "Show Code Review", "Pin Editor Tab", "Change Editor Orientation", "Enter
    Full Screen". Since this app is measured against Xcode, sentence-casing the menu bar would move
    *away* from parity, not toward it. Do not "fix" it.

  Everything drawn inside the window — buttons, alerts, context menus, section headers, empty-state
  copy — stays sentence case. That is the house style, applied consistently, and it is where modern
  Apple practice has moved.
- **Label/value rows put the label right-aligned in a fixed column and the value flush left**, so
  every value in a panel starts at the same x. Two columns pinned to opposite edges with a `Spacer`
  between them is what this replaced, and it read as a spec sheet. The column is sized to the panel's
  own longest label — see `InspectorRowMetrics`, which carries a different width per panel because
  the overview and the request detail are never on screen together.
- **Controls sharing a row share their geometry.** Height, corner radius, border weight and vertical
  padding come from one place, not from four independently written call sites — see the private
  `HeaderControl` enum and `headerControlWell` in `RequestLogDrawerView`. The row there used to carry
  four controls in three shapes at three heights.
- **Every interactive control answers the pointer.** A control that looks identical whether or not the
  pointer is on it is a control you find by trial. This is the defect that recurred most: the server
  toggle — the app's primary action — had no hover state at all, and so did the three copy buttons in
  the request detail, which are the ones a user hunts for. Reach for an existing component before
  hand-drawing one: `DSButton(.ghost, .small)` *is* accent text at 20pt with an `accentSubtle` well,
  and three call sites were spelling it out by hand, each leaving out the hover.
- **A menu needs a disclosure indicator at rest.** `DSFilterField`'s scope control was a bare glyph in
  the position a search field's magnifier occupies, so nothing said it opened anything. 8pt
  `chevron.up.chevron.down` beside the glyph is the idiom here, matching `BreadcrumbJumpBar`'s crumbs.
- **A filled colour swatch is for something that needs attention.** Status codes in the traffic list
  are coloured text; only 4xx and 5xx get a fill. A column of filled pills is a wall of colour that
  says nothing, because everything in it is shouting equally.
- **Nothing a user must read sits at `labelTertiary`.** It is 36% alpha — right for a timestamp or a
  separator, wrong for a control's own label. Unselected tab icons live at `labelSecondary` for this
  reason.
- **No glyph below 8pt, and the size comes from `DSGlyph`.** The ladder is `indicator` 8,
  `inlineSmall` 9, `inline` 10, `control` 11, `controlLarge` 12, `controlProminent` 13, with
  `minimum` 8 as the floor. A 7pt chevron is decoration that happens to be load-bearing.
  `AppFeatures` used to name none of these — two dozen `.font(.system(size: N))` literals instead —
  and now names all but two, both on the welcome window and both commented at the call site with why
  they sit off the ladder. `grep -rn '\.font(\.system(size: [0-9]' Sources` prints exactly those two;
  a third means somebody hand-wrote a rung.
- **A fixed frame around a `@ViewBuilder` that can produce nothing does not reserve its space.** A
  stack drops an `EmptyView` *together with the `.frame(width:)` wrapped around it*, so the column
  silently collapses and every sibling after it shifts by that width. The import review's flag column
  is 92pt and empty on most rows: those rows handed 92pt to the flexible path column that the header,
  whose `Text("")` is a real view, never gave its own — so Name, Status and Size each rendered about
  ninety points right of the title naming them, while Method and Path, being *before* the flexible
  column, lined up perfectly. It reads as the header being wrong rather than the row.

  **A conditional cell in a table needs an `else` that draws something** — `Color.clear` is enough.
  Audit for this by finding every `@ViewBuilder` containing an `if` with no `else`, then checking
  whether its call site wraps it in a fixed frame; that pair is the whole bug.
- **`.fixedSize()` on a string in a row is a latent clipping bug.** It makes the row demand more width
  than its container has, and an `HStack` resolves that by pushing its *leading* edge out of view —
  `DSPanelHeader` rendered "narios" instead of "Scenarios" for exactly this reason. Long strings get
  `.lineLimit(1)` and a truncation mode. Note also that `.layoutPriority(-1)` is not the fix: a
  `Spacer` claims slack at default priority, so a negative one makes the text vanish entirely.

## Panel chrome

The workspace is three panels around a centre pane: sidebar, request log, inspector. They follow one
set of rules, because they used to follow none and the window read as three unrelated things.

- **Every panel wears one bar of chrome, `DSBarHeight.panelHeader` tall.** Usually that is
  `DSPanelHeader` — one row, title left, controls right, count in the subtitle slot. The navigator is
  the exception: it wears a `DSTabStrip` instead, because the selected tab already names the list and
  a title row repeating it would cost a second 30pt band before the first endpoint. Both are the same
  height, so the three panels' headers still align horizontally. Header buttons are
  `DSPanelHeaderButton` in either — a bare `Image` in a `.plain` button gives an ~11pt hit target.
- **A bar's height comes from `DSBarHeight`, not from a literal.** Four rungs: `panelHeader` 30,
  `secondaryBar` 24, `controlRow` 32, `columnHeader` 22. The window once had ten, most of them
  emergent — a `.padding(.vertical)` around whatever AppKit's small controls happened to measure.
  Nobody chose 31, or 33, or 46. A bar that genuinely fits no rung (the request detail's identity row
  wraps to two lines, so it measures 46–59) stays content-sized and says so in a comment, so the next
  audit does not re-flag it.
- **A control's height comes from `DSControlHeight` and a line weight from `DSStroke`**, for the same
  reason and after the same failure. The rule above about controls sharing a row was being kept by
  hand: `DSButtonSize`, `DSTextField`, `DSFilterField`, `DSStatusBadge`, `RequestLogDrawerView`'s
  `HeaderControl` and `EndpointEditorView`'s `EditorField` each declared the same 20/22/28 ladder and
  the same 3pt inset privately — two of them across a module boundary, one with a comment promising
  it matched `DSFilterField` "so a panel that later adopts that component does not change shape on
  the way in". Six copies, and nothing checked that the promise held. The line weights were worse:
  twenty-three bare literals — eleven strokes, eight more hand-drawing the closing rule
  `DSDivider` exists to draw, three private constants, and `DSDividerStyle` itself.
  `Tests/DesignSystemTests` pins all three ladders by value, because an ordering assertion cannot
  catch `DSSpacing.md` going from 12 to 10.
- **A bar inside a pane takes `DSColors.band`; a panel's own header takes `DSColors.secondary`.**
  Column-header strips, section headers and the jump bar are the first kind. `band` is a tint, not the
  separator — the 0.5pt `DSColors.separator` rule each of them closes with does the separating, at
  ΔL\* ~10 against the band's 1.4–7.3. That is what Xcode's jump bar and AppKit's own table header do,
  and it is why the band being subtle in light mode is not a bug. Never wash the panel surface with a
  fraction of *itself*: `secondary.opacity(0.6)` over `secondary` is `secondary`, which is how the
  request log's column strip spent months being exactly the colour it was trying to differ from.
- **A panel's own controls are not part of its content.** The sidebar's search field used to be the
  first row *inside* the scrolling list, so it scrolled away exactly when a long list made it useful.
  Chrome is pinned above the scroll view.
- **The header stays when the content is empty.** Chrome that disappears with its content reads as a
  rendering glitch, and it made panels align differently depending on what was selected.
- **A panel with nothing to show earns its space or gives it back.** The inspector shows
  `InspectorOverview` — server state, counts, active journey, unmatched traffic — rather than 280pt
  reserved for the words "No selection".
- **Detail belongs in the tall panel, not the short one.** The request log used to split itself when
  you selected a row, which left the detail 74pt — about 11pt of readable body once its own chrome was
  paid for — and cost the list half its rows at the moment you most needed context. Request detail
  goes to the inspector (`InspectorPanelView.Mode`, precedence: request → endpoint → overview) and the
  drawer stays a list. A panel whose height is a user preference cannot also be the place a payload is
  read.
- **Panel geometry is a preference.** Sizes and visibility go through `PanelLayoutStore`, which takes
  an injected `UserDefaults` so a UI test run cannot overwrite a real window arrangement. Never reach
  for `@AppStorage` here: it binds to `.standard` and would do exactly that.
- **Anything a user drags is an `NSSplitViewItem`.** All three resizable panels are now split-view
  panes: the navigator via `NavigationSplitView`, the inspector via `.inspector`, and the request log
  via `DSSplitPane`. They match because they are the same mechanism, not because three sets of numbers
  were matched by hand — which is what the window used to do, and why one divider lit up blue on hover
  while the other two did nothing, one restored a default on double-click while the other two did not,
  and one forgot your size every time you dragged it shut.

  Do not resize a panel with a `DragGesture` writing a `@Binding<CGFloat>` into a `.frame`. That is a
  control loop — the gesture writes state, the state changes layout, the layout re-measures what the
  gesture reads — and SwiftUI promises no ordering between those steps. The old request-log divider
  crashed inside it (`NSInternalInconsistencyException` out of `_postWindowNeedsUpdateConstraints`,
  with the mouse still down), and rewriting it to use absolute pointer position made the loop
  idempotent without removing it.

  Three things `DSSplitPane` documents at length, because each one costs a day if you meet it cold: a
  SwiftUI pane claims every point of its own bounds, so a 1pt divider has no grab target left and will
  not drag at all; a pane holding its thickness above priority 490 outranks AppKit's own drag; and a
  custom `NSSplitView` installed from `loadView` needs `splitView(_:shouldHideDividerAt:)` guarded or
  the app will not launch.

## UI Changes — Definition of Done

When adding or modifying views or navigation:

1. **Add accessibility identifiers** to all interactive elements and key labels used for assertions.
2. **Write or update XCUITests** in `MimicUITests/MimicUITests.swift` covering the changed flows.
3. **Run the UI test suite** and verify it passes before considering the work complete.
4. **Keep test-only code out of production sources** — use `MIMIC_DEFAULTS_SUITE` for UserDefaults
   isolation, a **separate store** for persistence isolation, and `#if DEBUG` for launch hooks.

   **A UI test run must never open, and never delete, `mimic.sqlite`.** It used to do both: the suite
   launches the real app, the real app opened the real database, and `UITestSupport.resetApp` computed
   that same path and deleted it at the start of every test. Running the suite on a development
   machine silently destroyed the developer's projects and left the runner's fixtures in their place.
   It cost this repository a project before anyone noticed, because the damage looks exactly like
   "the recents list is empty".

   The isolation is now one property, `UITestSupport.databaseURL`, which `AppState` opens and
   `defaultResetContext` deletes — so the file a run writes and the file a run removes cannot drift
   apart. It resolves to `mimic-uitests.sqlite`, beside the real store rather than in `/tmp` because
   the app is sandboxed and Application Support *is* its container. It returns `nil` outside a UI test
   run, which is what makes the reset inert everywhere else, and a bare `MIMIC_DATABASE_PATH` does
   **not** arm it — `Scripts/run_cli_e2e.sh` exports exactly that to share a throwaway store with the
   CLI, and arming there would delete the store the script just set up.

   **The same rule binds anything that can destroy a store, not just a test reset.** GRDB's
   `eraseDatabaseOnSchemaChange` was set under `#if DEBUG` in `AppMigrations.migrator` — the migrator
   the app runs against the real `mimic.sqlite`. It drops the file and rebuilds it empty on any
   schema difference, and Debug is the configuration every developer runs, so the next migration
   anybody added would have deleted every project of everyone who pulled it, with the damage again
   looking exactly like "the recents list is empty". It is now opt-in via
   `MIMIC_ERASE_DB_ON_SCHEMA_CHANGE` **and** honoured only alongside an explicit
   `MIMIC_DATABASE_PATH`, so it can only ever reach a store somebody deliberately named. A
   convenience that erases must never be able to compute its own target.

   If you add another kind of persisted state, isolate it the same way: give the test run its own,
   and never let a reset compute a production path for itself.
5. **Use XCTest for UI tests** (Swift Testing does not support XCUITest).
6. **Launch through `UITestApp.launchAndBringToForeground`.** `XCUIApplication.launch()` returns once
   the process is running, which is not the same as having a window the accessibility layer can see —
   the app may come up hidden or behind the runner. A suite written without the activation retry fails
   every test on "welcome screen should appear", which reads like a broken app rather than a broken
   test.
7. **Check what AppKit actually realizes an element as.** A SwiftUI `Menu` in a toolbar becomes a
   `MenuButton`, not a `Button`, so `app.buttons[…]` never matches it; a `DSEmptyState`'s text arrives
   as the element's `value` rather than its label. When a query finds nothing, dump
   `app.debugDescription` and match against reality instead of guessing the element type.
8. **A container's `.accessibilityIdentifier` overrides its descendants', and `.contain` does not
   reliably stop it.** `WorkspaceView` tags the sidebar `"sidebar"`; every element inside it then
   reports that identifier instead of its own. The search field only escaped this while it lived
   inside a `List`, because list rows form their own accessibility elements — pinning it above the
   list made `sidebar.searchField` vanish from the tree and broke `testSidebarSearchFiltersEndpoints`.

   Pairing the identifier with `.accessibilityElement(children: .contain)` keeps each child as its
   own element carrying **its own label and value**. That is not the same as keeping its own
   *identifier*, and treating the two as equivalent has now cost this suite twice. Dumped from
   `app.debugDescription`:

   ```
   Button, identifier: 'ds.tabstrip.navigator', label: 'Show endpoints'
   Button, identifier: 'ds.tabstrip.navigator', label: 'Add endpoint'      ← set to sidebar.addEndpointButton
   StaticText, identifier: 'ds.panelheader.inspector', value: Overview     ← set to ds.panelheader.title.inspector
   StaticText, identifier: 'ds.empty.sidebar.endpoints', value: No endpoints
   ```

   All four are inside a container that *is* paired with `.contain`, and all four lost their own
   names. Whether the child's identifier survives depends on how SwiftUI collapses that particular
   subtree — `sidebar`, `centerPane` and `inspector` do not flatten the containers beneath them, but
   a `DSTabStrip`, a `DSPanelHeader` or a `DSEmptyState` flattens its leaves. **So the rule for a leaf
   control inside a named container is: target it by label, not by identifier.** Keep setting the
   identifier — it costs nothing and it lands whenever SwiftUI does not flatten — but never write a
   query that assumes it did without dumping the tree first.

   **The other exception, which matters:** when the propagation is the thing you want, do not pair it.
   A `DSTextField` tagged `"projectNameField"` forwards that name to the single text field inside it,
   which is exactly why `app.textFields["projectNameField"]` matches. Adding `.contain` there turns the
   element into a container and the query stops finding a text field at all — that pattern accounts for
   most of the sheet coverage in the suite. Pair the identifier when the container holds *several*
   things worth addressing; leave it alone when it wraps one control and lends it its name.

   When an identifier mysteriously stops matching, dump `app.debugDescription` and look at what the
   element is actually called. `MimicUITests/TreeDumpTests.swift` is not kept in the repo — write a
   throwaway test that prints `app.debugDescription` line by line, because the runner is sandboxed and
   cannot write the dump to a file.
9. **Never write `a.waitForExistence(t) || b.waitForExistence(t)`.** It waits out `a`'s entire timeout
   before it ever looks at `b`, so a short-lived `b` can appear and vanish inside `a`'s wait and the
   test fails claiming neither was seen. Use `UITestApp.waitForAny([a, b], timeout:)`, which polls
   them together. The autosave indicator is the case that bites: `.saving` lasts only as long as a
   SQLite write, and `.saved` clears after two seconds.

## CLI and Control Plane — Definition of Done

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
   `MimicControlService` *and* `AppControlHost`. Of that pair only `AppControlHost` is reachable in
   production — see "Two hosts, one of them shipped" — so it is the one to test and the one to check
   by hand against a running instance. Implement both anyway: they are meant to answer identically,
   and the cheapest way to keep that true is to write them together.

   **This step is not compile-enforced, and the documentation claimed for a long time that it was.**
   All three dispatch switches end in a `default:` — `ProjectCommandExecutor.apply`,
   `MimicControlService.run` and `AppControlHost.perform` (which has a second one in its
   project-lifecycle switch). Check it yourself in one command:

   ```bash
   grep -n 'default:' Sources/Domain/Control/ProjectCommandExecutor.swift \
                      Sources/ControlPlane/MimicControlService.swift \
                      Sources/AppFeatures/AppCore/AppControlHost.swift
   ```

   The three tails are deliberate, and the reason is written above each of them: each switch is over
   `ControlCommand` while its caller has already narrowed by `CommandKind`, so the compiler cannot
   see the narrowing, and closing a switch would mean re-listing every case it declines — twenty-one
   in the executor, twenty-six in each host, as `CommandKind.scope` partitions the surface today.
   Those two lists written out three times are exactly what `scope` was introduced to collapse into
   one, and neither number belongs in a document: `scope` is where it is decided and the only place
   it should be read. What each `default:` does instead is **throw and name the command**
   (`"<kind> is host-scoped but this service does not implement it."`), rather than falling through
   to `noProjectOpen` and telling a caller to open a project they already have open.

   So the compiler forces you to **classify** a command; tests force you to **implement** it, on
   both sides of the line and in both hosts:

   - `Tests/DomainTests/ControlCommandTests.swift` runs a sample of every kind through the executor
     from both directions — `hostScopedCommandsReturnNil` requires every host-scoped kind to be
     declined, `projectScopedCommandsAreApplied` requires every project-scoped kind to be answered —
     failing specifically on the error code `internal.failure`, which is the executor's `default:`
     saying in as many words that it has no arm for the command.
   - `Tests/MimicTests/HostParityTests.swift` does the same for the pair that has no compile check
     at all: `everyHostScopedCommandIsRoutedByBothHosts` walks `CommandKind.allCases` through
     **both** hosts with nothing open, `everyHostScopedCommandIsRoutedWithAProjectOpen` repeats it
     with a project seeded (skipping only `serverStart`, whose headless engine would bind a real
     port), and each asserts neither host answered from its unimplemented arm. It also mirrors the
     executor sweep, so one file covers the whole partition.
   - `Tests/MimicCLICoreTests/ControlTransportTests.swift` drives a list of `mimic` invocations
     through a recording transport and requires every `CommandKind` to have been emitted by one of
     them — so a command with no CLI verb fails there.
5. **Add a sample in the two places that hold one.** `HostParityTests.sample(for:)` is a switch over
   `CommandKind` with **no `default`**, so a new kind stops `MimicTests` compiling until you supply a
   payload — which is what keeps the sweeps above from quietly ceasing to cover the newest command.
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
10. **Never widen the control plane's binding** beyond `127.0.0.1`. It must stay unreachable from
   whatever the app under test can route to.

   The discovery file is the other half of that boundary, and it is a credential: it is written
   `0600` by setting the mode on a temporary file and then `rename(2)`-ing it into place. Do not
   reach for `Data.write(options: .atomic)` and a following `chmod` — `.atomic` renames, so the token
   sits at the final path at the umask default until the `chmod` lands, and stays there if it throws.
   Resolution reads `port` from that file and derives the host; it does not read `baseURL`, because a
   file that can name the host can send the token off-box.

   **A discovered token goes to the instance that advertised it, and nowhere else.** Destination and
   credential are now resolved together in `ControlClient.discover`: the token from `control.json` is
   attached only when the URL's *host* is loopback (`127.0.0.1`, `::1`, `[::1]`, `localhost`) **and**
   its port is the one that file advertised — `ControlEndpointFileReader.namesDiscoveredInstance`.
   They used to be resolved independently, so `mimic state --url http://attacker.example` posted this
   machine's live control-plane credential to that host in an `X-Mimic-Token` header. A caller
   legitimately reaching Mimic through a forwarded port or a container supplies the credential
   itself with `MIMIC_CONTROL_TOKEN`, which still wins — that is the caller naming a token rather
   than the CLI guessing one.

   **`mimic app stop` confirms before it signals.** It asks the instance the discovery file names for
   `.state` on that file's own port and requires the reported pid to match, because a file left by a
   crashed process can name a pid the system has since reused. It ignores `--url` for the same
   reason — a pid only means something on the machine the file was read from. Two things this
   forecloses, both deliberate: a *wedged* instance, and one whose file carries no token, can no
   longer be stopped by `mimic app stop`; the refusal names the pid and prints `kill <pid>`.

   **`MIMIC_CONTROL_FILE` relocates the discovery file** for a run that must not touch the shared
   one. `ControlEndpointFile.writeURL` and `searchURLs` honour it, the override *replaces* the search
   list rather than joining the front of it, and the parent directory is created `0700` on that path
   too — an isolated run is not a less sensitive one. `MimicCLICore`'s copy of the reader does **not**
   honour it yet; see the `run_cli_e2e.sh` section above.

## Skill Integration — Mandatory

**Five** skills are vendored into this repository, in `.agents/skills/`; `.claude/skills/` holds
symlinks to the same five, so Claude Code and other agents read one copy. Load and follow the
relevant skill when working in its domain.

| Skill | Vendored? | Trigger | Governs |
|-------|-----------|---------|---------|
| **swiftui-pro** | yes | Any SwiftUI view code | Modern APIs, no deprecated modifiers, data flow, accessibility, HIG, performance |
| **swift-testing-pro** | yes | Any unit/integration test | `@Test`, `#expect`, async patterns |
| **swift-concurrency-pro** | yes | Any async/await, actor, Task, Sendable code | Actor isolation, structured concurrency, cancellation, MainActor |
| **using-tuist-generated-projects** | yes | Any Tuist/`xcodebuild`/config work | Buildable folders, target tagging, build configs, workspace workflows |
| **improve-codebase-architecture** | yes | Deepening a module, moving a boundary | Testability, module depth, consolidating shallow glue |
| **xcuitest-pro** | **no** | Any XCUITest code | Page object pattern, accessibility-first targeting, deterministic launch contracts, no `sleep()` |

`xcuitest-pro` is **not in this repository** — `find . -iname '*xcuitest*'` returns nothing, and the
row is kept only so that nobody re-adds the reference believing it was an oversight. It is listed
because agents run with their own skill sets and some do carry one; if yours does, use it. If yours
does not, the XCUITest rules that matter here are written out in full in "UI Changes — Definition of
Done" above, which is where the repo's actual, hard-won contract lives — the accessibility-identifier
flattening, the launch/activation retry, and the `waitForAny` rule are all things a generic skill
would not tell you.

`improve-codebase-architecture` is vendored from `mattpocock/skills` and pinned in
[`skills-lock.json`](skills-lock.json); the other four are local.

How to load: read the skill's `SKILL.md` (lightweight index), then pull what it points at — the three
`*-pro` skills carry a `references/` directory, `improve-codebase-architecture` a single
`REFERENCE.md`, and `using-tuist-generated-projects` nothing but its `SKILL.md`. Multiple skills can
apply at once.

### Non-negotiable patterns

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
