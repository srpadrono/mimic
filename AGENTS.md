# AGENTS.md

Guidance for AI assistants and contributors working in this repository. This is the single source
of truth; `CLAUDE.md` points here.

## What is Mimic?

Mimic is a native macOS app for building and running local mock API servers: define endpoints,
configure responses, switch scenarios, script **journeys**, simulate latency and network failures,
and inspect live request traffic — so client work can start before the backend is ready. The embedded
Vapor server runs **in-process** (direct Swift calls, never HTTP-to-self).

Mimic is also drivable entirely from a script. The `mimic` CLI and a loopback HTTP control API expose
every operation the window offers, so a UI test or an AI agent can create configurations, script
flows, and drive a run without touching the interface.

Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the domain language and the reasoning
behind the module boundaries. Then [docs/JOURNEYS.md](docs/JOURNEYS.md) for the journey model,
[docs/CLI.md](docs/CLI.md) for the command surface, [docs/GRAPHQL.md](docs/GRAPHQL.md) for operation
matching, and [docs/ROADMAP.md](docs/ROADMAP.md) for what is deliberately not built yet.
[CONTRIBUTING.md](CONTRIBUTING.md) holds the build and test gates.

## Build & Test Commands

```bash
# Build (always use the workspace — Tuist resolves SPM deps into it)
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Debug build

# Unit suites run through the aggregate Mimic-Workspace scheme. The per-module schemes
# build the frameworks but do not bundle their test targets.
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

# CLI end-to-end (launches Mimic headless against a throwaway store):
./Scripts/run_cli_e2e.sh
```

After changing `Project.swift` or `Tuist/Package.swift`, run `tuist install && tuist generate`.

### What CI actually covers

**CI is currently manual-only** (`workflow_dispatch`). GitHub Actions will not start a job on this
account: runs are created and die in ~2s having executed zero steps, on Linux and macOS alike,
because of a billing block. That is not a workflow error — the same commands pass in the `swift:6.2`
container the job uses. Do not debug the YAML in response to those failures; verify in Docker
instead. The automatic triggers are commented out in `.github/workflows/ci.yml` and can be restored
once the account is unblocked.

When it does run, CI is Linux-only and builds through [`Package.swift`](Package.swift) rather than
Tuist: the domain rules, mock engine, persistence, control plane, spec import and CLI are plain
Swift, so 455 of the tests run on a free runner instead of a macOS one billed at 10×. Both manifests
point at the same directories, so they cannot drift in what they compile — only in how targets are
declared.

What CI does **not** cover, because it needs Xcode: the app bundle, SwiftUI, the app-level suites, the
Release gate, and XCUITest. Run `./Scripts/ci.sh` locally before landing UI changes.

When touching anything the Linux build compiles, remember it is not macOS: `URLSession` lives in
`FoundationNetworking`, the BSD socket calls live in `Glibc` rather than `Darwin`, and some C types
are wider there. `Tests/MockServerEngineTests/PlatformSockets.swift` keeps those differences in one
place — verify with `docker run --rm -v "$PWD":/src -w /src swift:6.2 …` rather than guessing.

### Testing against real inputs

Two shipped bugs came from fixtures that were tidier than reality: a replayed `Content-Encoding: gzip`
broke every real HAR import, and an appended `Content-Type` was emitted twice. When adding a feature
that consumes external input, add a case built from something a real server or browser produces —
`Tests/SpecImportTests/RealCaptureTests.swift` and `Tests/MockServerEngineTests/RealTrafficTests.swift`
are the homes for those.

## Project Configuration

- **Platform:** macOS 26.0+
- **Swift:** 6.2 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`
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
- **ControlPlane** — the automation surface: a loopback HTTP control API over the same engine and
  store the window uses, plus a headless service for CI.
- **SpecImport** — HAR/OpenAPI/Swagger parsing into `ImportCandidate`s.
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
- **No glyph below 8pt.** Separators and menu indicators are 8pt, inline glyphs 9–10pt, control
  glyphs 11–13pt. A 7pt chevron is decoration that happens to be load-bearing.
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
2. **Handle it in `ProjectCommandExecutor`** if it is project-scoped; otherwise in
   `MimicControlService` *and* `AppControlHost`.
3. **Add a `CommandCatalog` descriptor** — `DomainTests` asserts the catalog covers every case, so a
   missing entry fails the build's tests rather than silently shipping an undiscoverable command.
4. **Add the CLI subcommand** and a parse test in `MimicCLICoreTests`.
5. **Keep the exit-code contract**: `0` success, `2` bad usage, `3` no reachable instance, `4` command
   failed.
6. **Never widen the control plane's binding** beyond `127.0.0.1`. It must stay unreachable from
   whatever the app under test can route to.

## Skill Integration — Mandatory

Specialized skills are installed in `.agents/skills/` and `.claude/skills/`. Load and follow the
relevant skill when working in its domain.

| Skill | Trigger | Governs |
|-------|---------|---------|
| **swiftui-pro** | Any SwiftUI view code | Modern APIs, no deprecated modifiers, data flow, accessibility, HIG, performance |
| **xcuitest-pro** | Any XCUITest code | Page object pattern, accessibility-first targeting, deterministic launch contracts, no `sleep()` |
| **swift-testing-pro** | Any unit/integration test | `@Test`, `#expect`, async patterns |
| **swift-concurrency-pro** | Any async/await, actor, Task, Sendable code | Actor isolation, structured concurrency, cancellation, MainActor |
| **using-tuist-generated-projects** | Any Tuist/`xcodebuild`/config work | Buildable folders, target tagging, build configs, workspace workflows |

How to load: read the skill's `SKILL.md` (lightweight index), then pull specific `references/*.md`
as needed. Multiple skills can apply at once.

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
