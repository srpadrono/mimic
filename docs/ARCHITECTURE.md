# Architecture

Mimic runs a Vapor mock server inside the macOS app process. The UI and control host call Swift code directly; there is no HTTP call from the app to itself. The `mimic` CLI is a client of the token-protected loopback control API.

## Domain language

| Term | Meaning |
| --- | --- |
| Project (`MockProject`) | Saved endpoints, journeys, and server configuration. |
| Endpoint | Method and path, optionally scoped to a backend, with one active scenario. Literal path segments outrank `:param` wildcards. |
| Scenario | A response choice for an endpoint: status, headers, body, and content type. |
| Journey | An ordered set of steps that overlays endpoints; at most one is active per project. Unscripted requests can fall through to endpoints. |
| Journey step | A response, connection drop, or timeout, optionally repeated. |
| Request log | In-memory record of what was served, passed through, blocked, or unmatched. |
| Control command | The shared operation vocabulary for the window, CLI, and HTTP API. |

See [Journeys](JOURNEYS.md), [GraphQL](GRAPHQL.md), and [CLI](CLI.md) for behavior and examples.

## Modules

```text
Mimic app → AppFeatures → Domain
                        → Persistence      → Domain
                        → MockServerEngine → Domain + Vapor
                        → ControlPlane     → Domain + Vapor
                        → SpecImport       → Domain
                        → DesignSystem
                        → UI sections      → Domain + DesignSystem + FeatureSupport

mimic CLI → MimicCLICore → Domain + ArgumentParser

MimicGallery (Debug tool) → UI sections + MimicFixtures + SnapshotSupport
```

The app target links each module for bundling, while its source imports `AppFeatures` as the composition root. `Package.swift` builds portable modules from the same source folders that `Project.swift` uses for the app.

- **Domain** holds value models, matching, `JourneyResolver`, `MockResolver`, validation, `ControlCommand`, `ProjectCommandExecutor`, and command discovery. It uses Foundation; `ControlEndpointDiscovery` is its deliberate file I/O and process-liveness exception.
- **MockServerEngine** serves HTTP, applies delays and transport failures, and owns the live journey cursor and request-log stream. Cursor read, resolution, and advance happen inside one actor hop.
- Engine configuration, routes, project identity, and the journey cursor are read from one ordered snapshot for each accepted request. The log stream is lossless for requests whose bodies complete within the limits: a handler takes one of 32 active slots and one of 64 pending-log slots before collecting a streamed request body or resolving a route. The active slot remains held through a delayed response even if its log is processed early; the runtime returns the log slot after automatic capture. Excess requests get `503` with `X-Mimic-Rejection: admission-capacity`, without advancing a journey or contacting an upstream. Saturation responses are not logged; logging them would consume the slot they were rejected for lacking. The runtime separately caps visible history at 1,000 entries. Request bodies are capped at 10 MiB and return `413` above that limit. A body that stalls after admission gets `408` after 10 seconds; Mimic closes its connection, releases its slots, and does not resolve a route, advance a journey, or log the request. Vapor can still receive some bytes before a route handler starts, so this is an admission bound, not a strict whole-process memory ceiling.
- **Persistence** implements `ProjectRepository` with GRDB. A newer project schema or malformed stored identity or response behavior is refused on load rather than partially read and resaved. Saves recheck the stored schema inside their write transaction, so an older snapshot cannot overwrite a project upgraded by another build. Project listings use stable columns so one unreadable backend payload does not hide the other projects. Backups are published only after SQLite finishes the snapshot. Each store keeps its own retention set in `Backups/<store filename>/` beside the source file. Unassigned copies in the older shared `Backups/` directory remain untouched and accessible in Finder.
- **ControlPlane** contains the loopback `ControlServer`, the `0600` discovery file, and `ControlHost` protocol. It depends on Domain and Vapor, not Persistence or MockServerEngine.
- **SpecImport** parses HAR and OpenAPI/Swagger into candidates reviewed in the window. Imports create primary-backend endpoints, so duplicate detection compares existing primary routes and earlier usable candidates using Domain's matching identity. Unavailable, partial, binary, oversized, or invalid responses remain visible with an explanation and do not displace a later usable capture. Neither ControlPlane nor the CLI links it.
- **DesignSystem** holds `DS*` SwiftUI tokens and components. Each token enum in `Tokens/` is one ladder with no legacy aliases: `DSColors` (surfaces, labels, status and syntax inks), `DSTypography` (roles after the macOS text styles), `DSSpacing` (a 4 pt grid), `DSCornerRadius`, `DSControlHeight`, `DSStroke`, `DSLayout`, `DSBarHeight`, `DSRowHeight`, `DSGlyph`, `DSSheetWidth`, and `DSAnimation`. Components build only on those tokens; for example, `DSPanelHeader` draws every panel's title bar, `DSMethodLabel` and `DSStatusLabel` render methods and statuses as colored text, `DSPill` draws the short facts beside a row, `DSTable` gives the request log and the import review one table look, and `dsFieldChrome` gives a bare text field the shared field look. A look two sections share is a `DS*` component (or, when it needs `Domain` or `FeatureSupport` words, a `FeatureSupport` view such as `StatusCodeField`), drawn on the Components board and listed in `DSCatalog` so the gallery scores it. Its shared JSON scanner bounds display formatting so a captured body cannot expand without limit; the editor enables Format only when valid JSON can be reflowed within that same output budget. Native text editors preserve undo and UTF-16 selection within a document and reset undo when document identity changes. Callers must update the identity together with the draft body it identifies.
- **AppFeatures** is the composition root. `AppState` owns the session, `ProjectWorkspace` owns project lifecycle, `MockServerRuntime` coordinates the live engine, and `AppControlHost` implements the only production `ControlHost`. `WorkspaceView`, `CenterPaneView`, and `InspectorPanelView` place the sections into the shell and wire their callbacks to `AppState`; `AppState` conforms to each section's model protocol in `AppState+FeatureModels.swift`.
- **UI sections** are one framework each, described under [UI sections](#ui-sections).
- **MimicCLICore** formats and sends commands. It does not host a server or open the project database.

`Scripts/check_module_edges.py` verifies the important dependency boundaries in both manifests.

## UI sections

Each part of the window is its own framework, so it can be built, tested, previewed, and matched to its design without the app, the server, or the store.

| Module | Holds |
| --- | --- |
| `WorkspaceShell` | `WorkspaceShellLayout` (navigator, jump bar, centre, docked request log, inspector and toolbar as slots) and its content card `WorkspaceDetailColumn`, the workspace toolbar (`WorkspaceToolbar`, with Run and the server well as slots) and its `WorkspaceToolbarLayout` tiers, the jump bar, autosave status, and the inspector overview. |
| `EndpointsFeature` | Endpoint navigator, editor, scenario inspector, request and new-endpoint sheets, and the first-endpoint chooser. |
| `JourneysFeature` | Journey navigator, editor, run controls, step inspector, and the step, capture and template sheets. |
| `RequestLogFeature` | Request log table, filters and sorting, request detail, and export. |
| `ServerFeature` | Run control, server status, and server settings. |
| `ImportFeature` | HAR and OpenAPI review, and committing the reviewed candidates. |
| `ProjectsFeature` | Welcome window and new-project sheet. |
| `UpdatesFeature` | The update sheet. The feed, download and installer stay in AppFeatures. |
| `FeatureSupport` | Pieces more than one section uses: `NavigatorTab`, `RenameItemSheet`, `SheetRequestField`, `HTTPStatusText`, `ImportKind`, and `PortProbe`. |

A section depends only on Domain, DesignSystem and FeatureSupport; ImportFeature also depends on SpecImport. A section never imports AppFeatures, Persistence, MockServerEngine, ControlPlane, or another section, and `check_module_edges.py` fails the build if one does. A section takes values and callbacks, or reads and edits through a model protocol it declares (`JourneyEditingModel`, `ServerSettingsModel`, `UpdateSheetModel`). Each protocol has a Debug-only stand-in (`JourneyPreviewModel`, `ServerSettingsPreviewModel`, `UpdateSheetPreviewModel`) that the gallery, previews and tests use. Hosted panes receive their model as an argument rather than from the environment, because `NSHostingController` does not carry the environment across.

Something two sections both need belongs in FeatureSupport, or in Domain if it is a rule. Wiring between sections belongs in AppFeatures.

### Working on one section

- **Tests.** Sections have their own test targets (`EndpointsFeatureTests`, `JourneysFeatureTests`, and so on), each building only its module and what it depends on: `xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test -destination 'platform=macOS' -only-testing:EndpointsFeatureTests`. Tests that need several sections, or a section inside the window, stay in `MimicTests`.
- **Gallery.** The `MimicGallery` scheme is a Debug-only app that lists every design-system component and every section, drawn from `MimicFixtures` at the size of its artboard. It switches between dark and light and lays the design over the live view as an overlay, a difference blend, or side by side. To show one section only, set `MIMIC_SECTION` in the scheme's environment (Product › Scheme › Edit Scheme › Run › Arguments) to an entry id (`journeys.navigator`), an id prefix (`journeys`) or a sidebar group (`Request log`); separate several with commas. The Windows group has the endpoint editor window, the journey editor window, and the empty window skeleton, whose panels only name their slots. A toolbar draws only in a window's title bar, so on the canvas the Toolbar group lays its items out as a strip, one entry per state of the toolbar design, and window entries have an Open in a window button that shows them with their real toolbar. The build copies `Design/Reference` into the app, so the gallery reads its artboards from its own bundle rather than the checkout, and macOS does not ask it for the folder the checkout lives in. Rebuild after re-exporting the references. It never ships: the `Mimic` app cannot reach it, the fixtures, or the snapshot harness.
- **Design references.** `Design/Canvas` holds the design canvas's artboards. `swift Scripts/export_design_references.swift` renders each one to a 2x PNG in `Design/Reference` with WebKit, the engine that has SF Pro. `Design/Reference/sections.json` names where each section sits on its artboard, in points. Re-run the exporter and commit its images whenever an artboard changes.
- **Fidelity reports.** `DesignFidelityTests` renders every gallery entry in both appearances with `SnapshotSupport` and scores it against its crop of the artboard. The scores are a report, never a failure, because WebKit and AppKit never rasterise text identically. The report is written to `$MIMIC_FIDELITY_REPORT`, or to the temporary directory, with an `index.html` that shows each section, its design, and their difference. The gallery's Export report button writes the same report. `MIMIC_SECTION` narrows the report the same way; `xcodebuild` passes it to the tests as `TEST_RUNNER_MIMIC_SECTION`. The suite does fail if a gallery entry names a section the manifest lacks, if a section has no gallery entry and is not on the test's commented reference-only list, or if an entry is drawn at a size other than its artboard's.

When the open project changes, `AppState` requests a server stop before publishing the new project. `MockServerRuntime` waits for that stop, including a bind still in progress, before pushing the new project's routes to the engine. The welcome list reads stored projects asynchronously; only its newest refresh may publish rows. `AppControlHost.projectList` reports a store failure if project counts cannot be read, rather than presenting missing counts as zero.

## One rule and one host

Every project-scoped command is applied by `ProjectCommandExecutor.apply(_:to:)` in Domain. Its optional result declines host-scoped commands; its mutation flag tells the host when to persist and update the engine. The window, CLI, and HTTP API use this rule instead of maintaining separate implementations.

Stateful commands go to `AppControlHost`. `mimic daemon start` launches `Mimic.app` with `MIMIC_HEADLESS=1`; it is the same host without a window. `ControlServerTests` verifies the HTTP adapter, while `HostCommandSweepTests` exercises the production host. Do not add a second store or engine under ControlPlane.

`CommandKind` classifies each operation as project or host scoped. Adding an operation requires a `ControlCommand` case, a matching `CommandKind` case and scope, implementation, sweep samples, catalog descriptor, CLI verb, and tests. See [Contributing](../CONTRIBUTING.md#adding-behavior).

## Serving order

For each request, Domain resolves an active journey step first, then the best matching endpoint. If neither handles it, the selected backend may pass it to an upstream; otherwise Mimic returns an unmatched `404`. A journey can explicitly block fallthrough. Global and endpoint or step delays are additive, with a 5-minute cap on the effective wait including any timeout hold. The engine records the actual outcome in the request log. The resolution rules are pure; the actor owns only live state and I/O.
