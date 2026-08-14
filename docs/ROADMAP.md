# Roadmap

What Mimic does today, where it stops, and what's being considered next. Nothing below is a
commitment or a date.

## Shipped

| Area | State |
|------|-------|
| Projects | Create, open, duplicate, rename, delete, recents, autosave, JSON export/import. |
| Endpoints | `GET`/`POST`/`PUT`/`PATCH`/`DELETE`/`HEAD`/`OPTIONS`, `:param` wildcards, most-specific-route resolution, group tags. |
| Scenarios | Multiple responses per endpoint, one active, switchable live. |
| Journeys | Ordered response sequences, two match modes, transport failures, held/automatic progression, restart and loop, nine templates. |
| Latency | Additive global and per-endpoint (or per-step) delays, applied before responding. |
| Request log | Live, with request *and* response, outcome labelling, and an unmatched filter. |
| Import | HAR captures and OpenAPI/Swagger specs, reviewed before commit. **Window only** — see the gaps below. |
| GraphQL | Matching by operation, with fallback for anonymous queries; import splits per operation. |
| Automation | `mimic` CLI and a loopback HTTP control API covering 47 operations: every project, server, endpoint, scenario, journey and request-log operation the window has. |
| Headless | `mimic daemon start` for CI and agents — the app, windowless. |

## Known gaps

Real limitations, not planned work:

- **Spec import is the one workflow a script cannot reach.** Everything else the window does is a
  `ControlCommand`; parsing a HAR or an OpenAPI/Swagger document into endpoints is not, because
  `SpecImport` is linked by `AppFeatures` and the app bundle alone — neither `ControlPlane` nor
  `MimicCLICore` depends on it, in either manifest, which
  [`Scripts/check_module_edges.py`](../Scripts/check_module_edges.py) checks on every CI run rather
  than leaving to review. An agent that wants a spec's routes parses the file itself and issues
  `endpointCreate` + `scenarioUpdate` per route, which is what the window's own review sheet does on
  commit, so nothing about the resulting project differs. What is missing is the parse and the
  review, and closing the gap means a command that carries a document and returns candidates — a
  larger change than it looks, because it would give `ControlPlane` a dependency it has deliberately
  never had. Note that `mimic project import` is a different operation: it reads a Mimic project
  export.
- **`mimic daemon start` runs the app, not a daemon — by decision now, not by accident.** It sets
  `--headless` on `mimic app start`, which launches `Mimic.app` with `MIMIC_HEADLESS=1`; the app
  hides its Dock icon and serves the control API through `AppControlHost`, the same code path the
  window uses. The windowless composition root that used to sit unreachable beside it
  (`MimicDaemon` + `MimicControlService`) was deleted by the owner rather than wired up, so a
  headless Mimic keeps needing the app bundle — the accepted cost — and every rule is implemented
  once. Revisiting that trade means bringing the pair back from git history *and* giving it a real
  binary; `Scripts/check_module_edges.py` fails CI on the store/engine edges it would need, so the
  revisit is a visible argument rather than an accretion. Detail in
  [ARCHITECTURE.md](ARCHITECTURE.md#one-host).
- **Matching ignores headers and body.** A request is routed by method, path, and — for GraphQL —
  operation. Two calls that differ only in their body or in an auth header cannot be told apart. The
  matcher already receives both, so this is a feature that hasn't been built rather than a design
  wall.
- **No dynamic responses.** Bodies are static text: no templating, no echoing request values back,
  no counters beyond a journey step's `repeatCount`.
- **No passthrough.** Mimic can't proxy unmatched requests to a real backend, which is the usual way
  to mock one service and leave the rest live.
- **Beta, and versioned below 1.0.** The interface and the stored project format may still change
  between releases.
- **One active journey per project.** Enough for a test case; not enough to model two independent
  clients against one server.

## Under consideration

Roughly ordered by how often the gap gets hit:

1. **Header and body matching** — the largest gap, and the matcher already has the inputs.
2. **Passthrough for unmatched requests** — mock one endpoint, let the rest reach a real backend.
3. **Response templating** — echo path params and request fields into the body.
4. **Journey assertions** — let a journey declare the calls it *expects*, so a test can fail on a
   missing call and not only on a wrong response.

## History

Version-by-version detail is in [CHANGELOG.md](../CHANGELOG.md). The phase-by-phase build log that
used to live here, and the original product requirements document, were removed once they stopped
matching the code — both remain in git history.
