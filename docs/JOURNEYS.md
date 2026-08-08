# Journeys

A **journey** is an ordered script of responses. Endpoints answer *"what does `GET /account-summary`
return?"*; a journey answers the harder question — *"what does it return **the second time**, after
the retry?"*

That difference is the whole feature. A response that depends on where the request falls in a flow
lets a UI test drive a complete application scenario deterministically, instead of stubbing one route
at a time and hoping the ordering works out.

## The canonical example

```
1. POST /login            → 200
2. GET  /account-summary   → 500
3. GET  /inbox             → 200
4. GET  /account-summary   → 200
```

The first account load fails, the user navigates to the inbox, and the retry succeeds. Two steps
target the *same* route with different outcomes; the journey's position decides which one answers.

```bash
mimic journey add-template retry-after-failure --activate
mimic server start
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/login            # 200
curl -s -o /dev/null -w '%{http_code}\n'      http://127.0.0.1:8080/account-summary     # 500
curl -s -o /dev/null -w '%{http_code}\n'      http://127.0.0.1:8080/inbox               # 200
curl -s -o /dev/null -w '%{http_code}\n'      http://127.0.0.1:8080/account-summary     # 200
```

## Journeys overlay endpoints; they do not replace them

While a journey is active it gets first refusal on every request. Anything it does not script falls
through to the endpoint's active scenario, so **a journey only has to describe the steps that matter
to the scenario under test**. A flow that cares about two calls needs two steps, not a full mock of
your API.

Set `unmatchedBehavior` to `notFound` when you want the opposite: any unscripted call answers `404`,
which turns "this flow must make exactly these calls" into an assertion.

## Matching

Real clients fire requests concurrently and in orders no script can predict, so the default is
forgiving.

| Mode | Behaviour |
|------|-----------|
| `orderedPerEndpoint` *(default)* | The earliest unexhausted step at or after the cursor that matches the request wins, even if earlier steps for *other* routes are still pending. Two `/account-summary` steps are consumed fail-then-succeed whether or not `/inbox` happened in between. |
| `strictSequence` | Only the step at the cursor may match. Anything else takes `unmatchedBehavior` and leaves the cursor alone. Use when the call order *is* the thing under test — e.g. asserting a client never skips an MFA challenge. |

Steps match paths with the same rules as endpoints: `/` separated segments, where a `:name` segment
matches anything. Query strings never participate.

## What a step can do

A step either **responds** or **fails at the transport level** — never both.

| Field | Meaning |
|-------|---------|
| `statusCode` | The status to answer with. |
| `headers` | Response headers. A `Content-Type` here replaces the default rather than duplicating it. |
| `body` | Response body. |
| `contentType` | `json` (default) or `text`. |
| `delayMs` | Artificial delay for this step, **added to** the project's global delay. |
| `repeatCount` | How many times the step answers before the journey moves on. `3` models a poll that stays `202` for three calls. |
| `failure` | `connectionDrop` or `timeout(holdMs:)` — see below. |

### Transport failures

An HTTP 500 is a *reply*. A dropped socket or a stalled request exercises entirely different client
code: retry policy, timeout configuration, offline banners. Those cases cannot be expressed as a
status code, so they are their own outcome.

- **`connectionDrop`** — the response is torn down instead of completed. The client's read fails.
- **`timeout(holdMs:)`** — nothing at all is sent for `holdMs`, then the connection is dropped. The
  client's own timeout fires first, which is what a timeout test is actually asserting.

One caveat worth knowing: HTTP clients are free to **retry** a failed idempotent request, and each
attempt is a new request as far as the journey is concerned. `URLSession` does this. Give a failure
step a `repeatCount` above 1 when a drop needs to survive the client's own retry.

## Progression

- **Automatic** (default) — a step retires once it has answered `repeatCount` times, and the cursor
  moves to the first step that has not.
- **Held** (`autoAdvance: false`) — the current step keeps answering until something advances it
  explicitly. This is how "the backend is in maintenance mode until I say otherwise" works;
  `mimic journey advance` is the switch that lifts it. In the window this lives in the **journey run
  bar**, beside Restart and Advance, rather than in a per-step field — it is a property of how the run
  behaves, and the run bar is where someone watching a run is already looking. The bar folds to two
  lines at pane width, which is why its 38pt is a `minHeight` floor and never a fixed height.
- **On completion** — `stop` (later requests fall through) or `restart` (the run resets and the
  journey replays, for soak tests).

`mimic journey restart` rewinds to step one at any time; activating a journey always begins a fresh
run, so switching between journeys needs no separate reset.

## Many journeys, one active

A project stores as many journeys as you like and at most one is active. Switching is a single
command — which is the point: a test suite keeps a journey per scenario and selects the right one in
its setup.

```bash
mimic journey list
mimic journey activate "Session expiry"
mimic journey deactivate            # back to plain endpoint mocking
```

## The template library

Nine ready-made journeys cover the scenarios teams reproduce most often. Each is also a worked
example of the step vocabulary, so it is a good starting point for writing your own.

**In the window, the template gallery *is* the empty state.** Open the Journeys navigator in a project
with none and you get the nine templates laid out to pick from, not the words "No journeys yet". That
is deliberate: journeys are the app's most valuable idea and its least obvious, and nine worked
examples teach the step vocabulary better than any paragraph — but they used to sit two clicks deep,
so the screen a new user actually met offered nothing to look at. Once a project *has* a journey the
pane means "you have not selected one", which is a different sentence and gets a different answer.

```bash
mimic journey templates
```

| Template | Scenario |
|----------|----------|
| `retry-after-failure` | Login succeeds, the first account load fails, the retry succeeds. |
| `payment-retry` | A charge is declined, the second attempt clears. |
| `session-expiry` | The session goes stale mid-flow and recovers after a token refresh. |
| `mfa-challenge` | Login demands a second factor; a wrong code is rejected before the right one is accepted. |
| `maintenance-window` | A held `503` with `Retry-After` until you advance the journey. |
| `progressive-loading` | A job polls `202` three times, slowly, then completes. |
| `offline-to-online` | A dropped connection, then a timeout, then recovery. |
| `feature-flag-rollout` | The flag payload flips between fetches, exercising both branches in one run. |
| `edge-case-responses` | Empty list, malformed JSON, `204`, and rate limiting. |

## Growing a journey from real traffic

The fastest way to build a flow is to run it once and capture what happened. In the request log,
right-click any request a journey did not answer:

- **Add to journey ▸ <name>** appends it to an existing journey.
- **Add to journey ▸ New journey from this request…** creates one named after the resource
  (`GET /account-summary` → *"Account summary flow"*) and seeds it with the step.

The captured step reproduces the response the client actually received — status, headers, body and
content type — so it replays exactly what you just observed. Two details are deliberate: the query
string is dropped, because it belongs to the call rather than the route a step matches; and for a
request nothing answered, the status is copied but the body is not, since that body is Mimic's own
diagnostic text rather than anything a backend would send.

### Capturing a whole session

Selecting several rows captures a flow in one go: ⌘-click to pick calls out of a session, ⇧-click to
take a stretch of it, then right-click the selection. The menu counts what it is about to take —
**Add 4 requests to journey ▸** — and naming a new journey happens in a sheet before it is created.

Three rules apply to a multi-request capture, and each of them matters:

- **Steps are ordered by when the calls arrived**, never by how the table happens to be sorted or the
  order rows were clicked. The log sorts by any column in either direction and defaults to
  newest-first, so capturing in display order would replay most flows backwards.
- **Requests an active journey already answered are dropped**, since they are steps in a journey
  already. The count in the menu reflects what will actually be captured.
- **A consecutive run of identical exchanges becomes one step with a `repeatCount`.** Six polls of
  `/status` are one step repeated six times. Only consecutive calls collapse, and only when the
  response matches too — a poll answering `202, 202, 202, 200` stays two steps, because that
  transition is the thing the journey exists to reproduce.

The equivalent from a script is `mimic journey step add-batch`, which appends a file's steps in a
single change. See [CLI.md](CLI.md).

## GraphQL flows

Every step of a GraphQL flow is the same `POST /graphql`, so steps take a `graphqlOperation`
discriminator to tell them apart. See [GRAPHQL.md](GRAPHQL.md).

## Journey files

A journey is portable as JSON. This is the form to commit alongside a test suite:

```json
{
  "name": "Retry after failure",
  "summary": "Login succeeds, the first account load fails, the retry succeeds.",
  "completion": "stop",
  "matchMode": "orderedPerEndpoint",
  "steps": [
    { "name": "Login",    "method": "POST", "path": "/login",           "statusCode": 200, "body": "{\"token\":\"t\"}" },
    { "name": "Fails",    "method": "GET",  "path": "/account-summary", "statusCode": 500 },
    { "name": "Inbox",    "method": "GET",  "path": "/inbox",           "statusCode": 200 },
    { "name": "Recovers", "method": "GET",  "path": "/account-summary", "statusCode": 200 }
  ]
}
```

```bash
mimic journey import flows/retry-after-failure.json --activate
mimic journey export "Retry after failure" -o flows/retry-after-failure.json
```

Exported files carry no identifiers and omit defaults, so they move between projects and read
cleanly in a diff.

## Watching a run

```bash
mimic journey status
```

```
Retry after failure — step 3/4, 2 served
  ✓ 0   POST    /login                        → 200
  ✓ 1   GET     /account-summary              → 500
  ▶ 2   GET     /inbox                        → 200
    3   GET     /account-summary              → 200
```

The request log records which step answered each request, and labels the outcome (`journey`,
`endpoint`, `unmatched`, `blockedByJourney`) — so a journey answering is never mistaken for a missing
mock, and `mimic log list --unmatched` still surfaces genuinely unconfigured calls while a journey is
running:

```bash
mimic log list --limit 5
```

## Using a journey in a test

```bash
# setup — deterministic starting point
mimic journey activate "Session expiry"
mimic reset --scope all

# … drive the app under test …

# assertion
mimic journey status | jq -e '.journeyStatus.isComplete'
```

`mimic reset --scope all` clears the request log and rewinds the journey, so every case starts from
step one.

## Where the rules live

Journey resolution is a pure function of `(request, journey, run state)` in the `Domain` module
(`JourneyResolver`, `JourneyRunState`), composed with endpoint matching by `MockResolver`. The engine
holds one run state and replaces it wholesale after each request inside an actor, so two concurrent
requests can never consume the same step.

That means the behaviour is testable as a table of requests in and responses out, with no sockets
involved — and the CLI, the HTTP control API, and the app window cannot disagree about it, because
they all call the same code.
