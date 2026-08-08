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
| Import | HAR captures and OpenAPI/Swagger specs, reviewed before commit. |
| GraphQL | Matching by operation, with fallback for anonymous queries; import splits per operation. |
| Automation | `mimic` CLI and a loopback HTTP control API covering every operation the window has. |
| Headless | `mimic daemon start` for CI and agents. |

## Known gaps

Real limitations, not planned work:

- **Matching ignores headers and body.** A request is routed by method, path, and — for GraphQL —
  operation. Two calls that differ only in their body or in an auth header cannot be told apart. The
  matcher already receives both, so this is a feature that hasn't been built rather than a design
  wall.
- **The request log's endpoint filter is window-only.** `RequestLogFilter` lives in Domain and carries
  `endpointID`, and the inspector's traffic count uses it to scope the log to one endpoint. But
  `mimic log list` exposes only `--unmatched` and `--journey-only`, so a script cannot ask the
  question the window answers with a click. This is the one place the redesign left the two surfaces
  unequal, and it is a small addition rather than a design problem: the filter is already in the
  shared module, so the work is a flag, a `ControlCommand` associated value, a `CommandCatalog`
  descriptor and a parse test.
- **No dynamic responses.** Bodies are static text: no templating, no echoing request values back,
  no counters beyond a journey step's `repeatCount`.
- **No passthrough.** Mimic can't proxy unmatched requests to a real backend, which is the usual way
  to mock one service and leave the rest live.
- **Beta, and versioned below 1.0.** The interface and the stored project format may still change
  between releases.
- **One active journey per project.** Enough for a test case; not enough to model two independent
  clients against one server.

## Deliberately deferred

Cut from the 2026 workspace redesign with the reasoning recorded, rather than forgotten. Each is
reopenable — see [redesign/decisions.md](redesign/decisions.md).

- **Request latency, everywhere it appears.** The column, the bar, the p95 scale, the inspector's
  latency row, the Overview card's median and `mimic log stats`. All of it reads a field the app has
  never recorded, and adding one touches the Domain model, the engine, the database schema, the
  redaction path, the wire format and the CLI. On a mock server the honest reading is either the
  delay the user configured — already visible in the editor — or 1–5ms of in-process overhead.
  Worth revisiting only if **record mode** lands, since that is the only thing that would produce
  timings worth charting.
- **The server segment's traffic sparkline.** Needs a ≤4Hz ticker running whether or not anyone is
  looking, costs ~30pt in the tightest part of the toolbar, and reports what the request count
  beside it already states.
- **The two-line "stream" layout for the request log.** A reasonable user preference alongside the
  default table — the log header has room for a Stream/Table toggle — but not specified, and not
  part of this pass.
- **Import review.** The redesign does not cover it. It is ported onto the new tokens and radii so
  it does not ship visibly older than the rest of the window, but its structure — a flag column
  empty on most rows, four fixed columns, sixty candidates to review — needs its own pass.

## Under consideration

Roughly ordered by how often the gap gets hit:

1. **Header and body matching** — the largest gap, and the matcher already has the inputs.
2. **Passthrough for unmatched requests** — mock one endpoint, let the rest reach a real backend.
3. **Signed and notarized releases** — removes the first-launch friction.
4. **Response templating** — echo path params and request fields into the body.
5. **Journey assertions** — let a journey declare the calls it *expects*, so a test can fail on a
   missing call and not only on a wrong response.

## History

Version-by-version detail is in [CHANGELOG.md](../CHANGELOG.md). The phase-by-phase build log that
used to live here, and the original product requirements document, were removed once they stopped
matching the code — both remain in git history.
