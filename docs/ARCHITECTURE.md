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

mimic CLI → MimicCLICore → Domain + ArgumentParser
```

The app target links each module for bundling, while its source imports `AppFeatures` as the composition root. `Package.swift` builds portable modules from the same source folders that `Project.swift` uses for the app.

- **Domain** holds value models, matching, `JourneyResolver`, `MockResolver`, validation, `ControlCommand`, `ProjectCommandExecutor`, and command discovery. It uses Foundation; `ControlEndpointDiscovery` is its deliberate file I/O and process-liveness exception.
- **MockServerEngine** serves HTTP, applies delays and transport failures, and owns the live journey cursor and request-log stream. Cursor read, resolution, and advance happen inside one actor hop.
- Engine configuration, routes, project identity, and the journey cursor are read from one ordered snapshot for each accepted request. The log stream is lossless for requests whose bodies complete within the limits: a handler takes one of 32 active slots and one of 32 pending-log slots before collecting a streamed request body or resolving a route. The active slot remains held through a delayed response even if its log is processed early; the runtime returns the log slot after automatic capture. Excess requests get `503` with `X-Mimic-Rejection: admission-capacity`, without advancing a journey or contacting an upstream. Saturation responses are not logged; logging them would consume the slot they were rejected for lacking. The runtime separately caps visible history at 1,000 entries. Request bodies are capped at 10 MiB and return `413` above that limit. A body that stalls after admission gets `408` after 10 seconds; Mimic forcibly closes its connection, releases its slots, and does not resolve a route, advance a journey, or log the request. Vapor adds its own `Connection: keep-alive` header even though this timeout response asks to close and the socket does close. Vapor can still receive some bytes before a route handler starts, so this is an admission bound, not a strict whole-process memory ceiling.
- **Persistence** implements `ProjectRepository` with GRDB. A newer project schema or malformed stored identity or response behavior is refused on load rather than partially read and resaved. Project listings use stable columns so one unreadable backend payload does not hide the other projects. Backups are published only after SQLite finishes the snapshot.
- **ControlPlane** contains the loopback `ControlServer`, the `0600` discovery file, and `ControlHost` protocol. It depends on Domain and Vapor, not Persistence or MockServerEngine.
- **SpecImport** parses HAR and OpenAPI/Swagger into candidates reviewed in the window. Imports create primary-backend endpoints, so duplicate detection compares existing primary routes and earlier candidates. Neither ControlPlane nor the CLI links it.
- **DesignSystem** holds `DS*` SwiftUI tokens and components. Its shared JSON scanner bounds display formatting so a captured body cannot expand without limit; the editor enables Format only when valid JSON can be reflowed within that same output budget.
- **AppFeatures** coordinates workflows. `AppState` owns the session, `ProjectWorkspace` owns project lifecycle, `MockServerRuntime` coordinates the live engine, and `AppControlHost` implements the only production `ControlHost`.
- **MimicCLICore** formats and sends commands. It does not host a server or open the project database.

`Scripts/check_module_edges.py` verifies the important dependency boundaries in both manifests.

When the open project changes, `AppState` requests a server stop before publishing the new project. `MockServerRuntime` waits for that stop, including a bind still in progress, before pushing the new project's routes to the engine. The welcome list reads stored projects asynchronously; only its newest refresh may publish rows. `AppControlHost.projectList` reports a store failure if project counts cannot be read, rather than presenting missing counts as zero.

## One rule and one host

Every project-scoped command is applied by `ProjectCommandExecutor.apply(_:to:)` in Domain. Its optional result declines host-scoped commands; its mutation flag tells the host when to persist and update the engine. The window, CLI, and HTTP API use this rule instead of maintaining separate implementations.

Stateful commands go to `AppControlHost`. `mimic daemon start` launches `Mimic.app` with `MIMIC_HEADLESS=1`; it is the same host without a window. `ControlServerTests` verifies the HTTP adapter, while `HostCommandSweepTests` exercises the production host. Do not add a second store or engine under ControlPlane.

`CommandKind` classifies each operation as project or host scoped. Adding an operation requires a `ControlCommand` case, a matching `CommandKind` case and scope, implementation, sweep samples, catalog descriptor, CLI verb, and tests. See [Contributing](../CONTRIBUTING.md#adding-behavior).

## Serving order

For each request, Domain resolves an active journey step first, then the best matching endpoint. If neither handles it, the selected backend may pass it to an upstream; otherwise Mimic returns an unmatched `404`. A journey can explicitly block fallthrough. Global and endpoint or step delays are additive, with a 5-minute cap on the effective wait including any timeout hold. The engine records the actual outcome in the request log. The resolution rules are pure; the actor owns only live state and I/O.
