# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.2] — 2026-08-04

### Fixed

- **The app no longer rebuilds itself continuously.** Opening a project used to put Mimic into a loop
  that held a full CPU core for as long as the window was open.

  Every evaluation of the app's body constructed a whole new `AppState` — which opens the SQLite
  store, runs the migrations and restores the open project — and then discarded it. Because that
  initialiser reads `currentProject` and then writes it, each pass invalidated the body that was
  still running, so the next pass began immediately. Measured on a running window with nothing
  touching it: about 150 database opens a second, indefinitely. macOS reports it as a CPU limit and
  a disk-write limit, both naming the same stack.

  Everything the window does happens on the main thread, so a main thread that never finishes is a
  window that answers the pointer late or not at all — resizing, dragging a divider, and clicking all
  degrade together. The session is now built once per process.

- **Resizing the request log no longer accumulates.** The panel divider resized from the drag's
  *translation* — a cumulative distance — added to a starting size held in view state. A layout pass
  can re-deliver a drag event, and a re-delivery re-read that starting size from a height the same
  drag had already moved, applying the distance twice and then again. Each round dirtied the window's
  constraints, and AppKit aborts a window that needs more constraint passes than it has views.

  It needed content in the panel to keep the geometry changing, which is why it showed up when the
  request log had traffic in it and not on an empty one.

  The divider now resizes from where the pointer *is*, measured against the panel's attached edge —
  the one edge a resize cannot move. Handling the same event twice produces the same height, so a
  re-delivery is a no-op rather than a step. This is the pattern Apple's guidance gives for a
  drag that affects layout.

### Known issues

- With the sidebar, request log and inspector all open, the window will not resize below roughly
  1560pt wide, because the inspector's current width acts as a floor on the window rather than its
  minimum. Hiding the inspector releases it. Not yet fixed.

## [0.9.1] — 2026-08-04

### Fixed

- **HAR import no longer rewrites response bodies.** A body is now reproduced exactly as captured.

  A redaction pass used to run over imported bodies, and it matched sensitive key names as a
  *substring* — so `author` matched on "auth", `keywords`, `keyboard` and `monkey` on "key", and
  `shipping`, `shopping`, `mapping` and `typing` on "pin". Ordinary fields in ordinary responses came
  back as `[REDACTED]`, which is a majority of real captures rather than an edge case.

  A second defect sat underneath it. The branch handling non-string values quoted its replacement, so
  `"sessionCount": 42` imported as `"sessionCount": "[REDACTED]"` — a number turned into a string,
  which fails to decode in any typed client even when the key really was a secret.

  An importer that edits the payload defeats the point of importing: the mock has to answer what the
  real server answered, or the client under test is being tested against something that never
  happened.

  Unchanged: credential *headers* are still dropped on import, and the request log served over the
  control API still redacts credential header values. [SECURITY.md](SECURITY.md) states plainly what
  a verbatim import now costs — a captured OAuth response lands with the real token in it, and the
  import review sheet is where that is caught.

## [0.9.0] — 2026-08-04

First beta.

Mimic runs local mock API servers on macOS, so client work can start before the backend is ready.
Define endpoints, configure responses, switch scenarios, script journeys, simulate latency and
network failures, and watch live request traffic. The server runs in-process.

Everything the window does is also scriptable. The `mimic` CLI and a loopback HTTP control API expose
the same operations, so a UI test or an agent can create a configuration, script a flow and drive a
run without touching the interface.

### Included

- **Endpoints and scenarios** — path matching with `:param` segments, global and per-endpoint latency,
  and scenarios that switch a whole set of responses at once.
- **Journeys** — ordered response sequences, so the same route can fail and then succeed. Per-step
  status, headers, body, delay and repeat count; transport failures; automatic or held progression;
  many stored, one active. A logged request can be captured straight into a step, so a flow can be
  built by running it once.
- **GraphQL** — requests matched by operation name rather than by path, falling back from the client's
  `operationName` to the name in the document to the first root field.
- **Import** — HAR captures and OpenAPI/Swagger documents become endpoint candidates you review before
  they land. Bodies are reproduced verbatim; credential headers are not replayed.
- **Request log** — live traffic with full request and response detail, formatted and syntax-coloured
  bodies, copy as `curl`, and unmatched requests called out so you can see the mocks you are missing.
- **CLI and control API** — the whole command surface over HTTP, bound to `127.0.0.1` only, with a
  per-instance token, JSON output and meaningful exit codes. Headless mode for CI and agents.

Ships as a signed and notarised installer that puts Mimic.app in `/Applications` and `mimic` in
`/usr/local/bin`.

Beta, and versioned below 1.0 deliberately: the interface and the stored project format may still
change between releases.

[0.9.1]: https://github.com/srpadrono/mimic/releases/tag/v0.9.1
[0.9.0]: https://github.com/srpadrono/mimic/releases/tag/v0.9.0
