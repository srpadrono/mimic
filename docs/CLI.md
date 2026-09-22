# The `mimic` CLI

Mimic's projects, endpoints, scenarios, journeys, server and request log, from a script. Built for
programs first: JSON on stdout, diagnostics on stderr, and exit codes that mean something.

**One thing the window does is not here: importing a spec.** `SpecImport` — the HAR and
OpenAPI/Swagger parsers — is linked by the app alone, so there is no `mimic import` and no `import`
command on the HTTP API. A script that wants a spec's routes reads the file itself and issues
`mimic endpoint create` and `mimic scenario update` per route — the same pair of operations the
window's review sheet runs when you confirm it, held to the same validation. Do not confuse this with
`mimic project import`, below: that reads a Mimic project document — the JSON `mimic project export`
writes — and refuses anything else.

## Contract

| Exit code | Meaning |
|-----------|---------|
| `0` | Success. |
| `2` | Bad usage — a malformed argument, a missing selector, an unknown subcommand, or a file this CLI could not read. |
| `3` | There is no Mimic to talk to: nothing is running or reachable, **or** Mimic itself is unavailable — not installed where the CLI looked, would not launch, or the process the discovery file names could not be confirmed or signalled. |
| `4` | The command reached Mimic and did not come back with a result — Mimic refused it, or answered with something this CLI could not read. |

`3` covers the whole "no Mimic" condition on purpose. "Could not find Mimic.app" and "could not
signal that pid" used to exit `2`, which told a script the *user* had mistyped something when what
had happened was that Mimic was not installed, or that the process its discovery file named was gone;
and inside `mimic app start`, the app-not-found failure and the app-never-answered failure are one
condition that was being reported under two different codes. The contract stays at four values, so no
existing branch has to learn a new one.

**On success, stdout carries the result and nothing else** — no envelope to unwrap, so a script
reads the field it wants directly:

```bash
mimic journey status | jq -e '.journeyStatus.isComplete'
```

```json
{ "journeyStatus": { "journeyName": "Session expiry", "isComplete": false, "totalSteps": 3, … } }
```

**On failure, stdout is empty.** The diagnosis goes to stderr as one plain line — `journey.notFound:
No journey matches name "Session expiry".` — and the exit code above says which kind of failure it
was. There is no `ok: false` object to test: **branch on the exit code**, and read stderr for the
sentence.

The `{"ok": …}` envelope is the *HTTP* wire shape rather than the CLI's. `POST /v1/command` answers
`{"ok": true, "result": {…}}` or `{"ok": false, "error": {…}}`, and `mimic` is the thing that
unwraps it: it prints `result` on success, and turns `ok: false` into exit `4` with `code: message`
on stderr. A verb that issues two calls — `journey create --activate`, `journey import --activate` —
checks the first for `ok` before anything is printed, so a failed one leaves stdout empty rather than
half-written. An agent talking to the API directly does branch on that boolean — see
[Talking to the API directly](#talking-to-the-api-directly).

Error codes are stable dotted `subject.reason` strings (`project.noneOpen`, `endpoint.notFound`,
`server.portInUse`), so a script matches on them without parsing English: as `error.code` on the
wire, and at the head of the stderr line from the CLI.

JSON keys are sorted and slashes are not escaped, so repeated calls diff cleanly. Add `--pretty` for
indented output and `--format text` for a human-readable rendering that carries the same information.

## Starting and stopping Mimic

```bash
mimic app start                # launch the app and wait until its control API answers
mimic app start --headless     # no window — for CI and agent workflows
mimic daemon start             # the same thing, named for the case it exists for
mimic app status               # is anything running, and what is it doing?
mimic app stop                 # SIGTERM, so pending saves flush
mimic app update-check         # has a newer Mimic been released?
```

"Pending saves flush" is a real guarantee now rather than an aspiration: the signal handler writes
the open project before it exits, bounded at two seconds so a wedged store cannot hang the quit.
Before that, `mimic endpoint create` followed immediately by `mimic app stop` could lose the endpoint
the first command had just reported creating — the app answers a control call and then debounces the
write by 500 ms, and the handler used to exit inside that window.

`app start` **waits for readiness** rather than sleeping a guessed interval, so the next command in a
script cannot race startup.

`app update-check` asks the **running instance**, so the version it reports as installed is the app's
own — read from its bundle — and not this command line tool's. That distinction is the reason the
command exists in this shape: the two are installed together by one `.pkg` and are meant to match, so
when they do not, the check prints a warning to stderr naming both. Nothing else in the system raises
that, and a `mimic` a release behind its app is a quiet source of wrong answers.

```json
{
  "update": {
    "installed": "0.10.0",
    "latest": "0.11.0",
    "updateAvailable": true,
    "releaseURL": "https://github.com/srpadrono/mimic/releases/tag/v0.11.0",
    "publishedAt": "2026-08-22T17:42:45Z",
    "assetName": "Mimic-0.11.0.pkg",
    "assetSizeInBytes": 54618197,
    "title": "Mimic v0.11.0"
  }
}
```

It exits `0` whether or not an update exists — "no update" is an answer, not a failure — so branch on
`updateAvailable`. A release feed that cannot be reached or read exits `4` with the code
`update.checkFailed`, which the HTTP surface answers as `502`: Mimic is fine, the service it had to
ask is not, and that is worth retrying where a `500` is not.

**Checking is a command; installing is not.** The window can download the installer, verify it
against the checksum GitHub publishes and the Developer ID it is signed with, and hand it to macOS's
`Installer.app` — which asks for an admin password. None of that is something a headless caller can
agree to on somebody's behalf, and a command that returned before the admin prompt would be reporting
a success that had not happened. So `mimic app update-check` tells a script that an update exists,
and a person installs it. Note that installing replaces `Mimic.app` **and** `/usr/local/bin/mimic`
together, because one package carries both.

`daemon start` is `app start --headless` — not a euphemism for it, the same code: `DaemonCommand.Start`
sets `headless` on an `AppCommand.Start` and runs it. Both launch `Mimic.app`, and `--headless` only
adds `MIMIC_HEADLESS=1` to its environment, which makes the app drop its Dock icon and open no
window. **There is no separate daemon binary**, and nothing about a headless run is a different
implementation: the commands below are answered by the same host that answers them with a window
open. Practically, that means a headless run still requires the app bundle to be present — installed,
or pointed at with `MIMIC_APP_PATH` — and still runs a full `NSApplication` event loop, which is why
the activation policy is `.accessory` rather than `.prohibited`. The upside is the one that matters
in a bug report: headless behaviour and on-screen behaviour cannot fork, because they are one binary
running one host.

`mimic app stop` and `mimic daemon stop` are likewise one thing: `SIGTERM` to the pid in the
discovery file — **but only after the instance has confirmed that pid is its own.** The CLI asks it
for `.state` on the port that same file advertises and compares the pid it reports; if that does not
line up, nothing is signalled and the message says how to stop it by hand. A file left behind by a
crashed process can name a pid the system has since given to something else, and a `SIGTERM` sent on
that evidence goes to a stranger.

Two consequences of the check are worth knowing before you meet them:

- **`mimic app stop` ignores `--url`.** A pid only means something on the machine its file was read
  from, so the instance asked to confirm is the one the file advertises, not one an environment
  variable points at.
- **A wedged instance can no longer be stopped this way**, and neither can one whose discovery file
  carries no token (a pre-token build under a newer CLI). Both refuse with the pid and a
  `kill <pid>` to run yourself. `SIGTERM` by hand still lets it flush and clean up; `SIGKILL` leaves
  the discovery file behind.

Set `MIMIC_APP_PATH` to run a build that is not installed in `/Applications` — an Xcode products
directory, for instance.

## Finding an instance

Resolution order, most explicit first:

1. `--url http://127.0.0.1:8787`
2. `MIMIC_CONTROL_URL`
3. `MIMIC_CONTROL_PORT` (host is always loopback)
4. The discovery file the running instance wrote

A discovery file left behind by a crashed process is skipped, so the CLI never hangs on a dead port.

**The token follows the instance, not the URL.** A token read out of `control.json` is a credential
for *one* instance, so it is attached only when the destination is that instance: a loopback host
(`127.0.0.1`, `::1`, `[::1]`, `localhost`) **and** the port the file advertised. Destination and
credential used to be resolved independently, which meant `mimic state --url http://attacker.example`
sent this machine's live control-plane token to that host in an `X-Mimic-Token` header. Anything
else — a remote host, a loopback-shaped name like `127.0.0.1.evil.example`, another port on this
machine — now goes out with no token and comes back `401` if one was needed. To reach an instance
through a forwarded port or from a container, set `MIMIC_CONTROL_TOKEN`, which is you naming a
credential rather than the CLI guessing one; it is taken first and this check never touches it.

## Environment

| Variable | Effect |
|----------|--------|
| `MIMIC_CONTROL_URL` | Full base URL of the control API. |
| `MIMIC_CONTROL_PORT` | Control port on loopback. Default `8787`. |
| `MIMIC_CONTROL_TOKEN` | Control API token. Normally unnecessary — the CLI reads it from the running instance's `control.json`. Set it on *both* sides when the caller cannot reach that file (a container, a forwarded port). |
| `MIMIC_DATABASE_PATH` | Where the project store lives. Point at a scratch file for a fully isolated run. |
| `MIMIC_CONTROL_FILE` | Where the discovery file lives. Honoured by both sides — the instance writes there, `mimic` searches only there — see below. |
| `MIMIC_HEADLESS` | Set by `--headless`; runs the app without a window. |
| `MIMIC_APP_PATH` | App bundle to launch. |

`MIMIC_DATABASE_PATH` is the one to reach for in CI: it gives a job its own store, open project
included, that can be deleted between runs.

`MIMIC_CONTROL_FILE` is the other half of that isolation, and both sides honour it. The instance
writes its `control.json` there, and `mimic` searches only there, because the override *replaces*
the default search list rather than joining the front of it — so an isolated run cannot fall through
to a developer's real instance in either direction. The path is resolved by one implementation,
`ControlEndpointDiscovery` in the `Domain` module, shared by the app's write side and the CLI's
reader, so the file a run writes and the file a run reads cannot drift apart. An isolated run
therefore needs only `MIMIC_DATABASE_PATH` and `MIMIC_CONTROL_FILE`: the destination *and* the
credential both come out of the relocated file. It used to need four variables — the CLI carried a
second copy of the discovery reader that ignored the override, so a run that moved the file had to
name the destination by hand and, easy to miss, `MIMIC_CONTROL_TOKEN` too, or every route answered
`401` while `mimic app start` still looked fine. `Scripts/run_cli_e2e.sh` still exports two more for
reasons that are not discovery: `MIMIC_CONTROL_PORT` is the *instance's* bind port, kept off the
default 8787 a developer's own Mimic may hold, and a fresh `MIMIC_CONTROL_TOKEN` per run means a
leftover file from an earlier run cannot authenticate against this one.

The parent directory is created `0700` and the file itself is written `0600` wherever it lands: it
carries the instance's token, and an isolated run is not a less sensitive one.

## Discovering the surface at runtime

A `--help` page goes stale the moment a version drifts. The running instance will tell you what it
actually accepts:

```bash
mimic commands            # every operation, with its CLI spelling
mimic state               # server, project, journey, and log counts in one call
```

## Command reference

### Instance

```bash
mimic ping
mimic state
mimic commands
mimic reset [--scope logs|journey|all]     # deterministic starting point for a test case
```

### Server

```bash
mimic server start [--port N]
mimic server stop
mimic server status
mimic server configure [--port N] [--delay MS] [--upstream https://api.example.com]
mimic server configure --disable-upstream
mimic server backend add --name Accounts --port 8081 --upstream https://accounts.example.com
mimic server backend update <UUID> [--name NAME] [--port N] [--upstream URL]
mimic server backend update <UUID> --disable-upstream
mimic server backend delete <UUID>
```

One project can listen on several local ports. The original port is the **primary backend**;
additional backends each have a stable UUID, name, local port, and optional real backend URL.
Point each of your app's existing backend settings at its corresponding local port. An endpoint
belongs to one backend, selected with `mimic endpoint create ... --backend <UUID>` or changed with
`mimic endpoint update ... --backend <UUID>`. Use `--backend primary` for the original port.
The project and server status JSON report the configured backends and ports.

Mimic tries a journey step, then an endpoint on that backend. When neither matches and that
backend has forwarding enabled and an upstream URL, Mimic forwards the original request, including its query, headers,
and body, and returns the real HTTP reply. An explicit journey block stays blocked. A backend
without active forwarding keeps the existing unmatched `404`. Select a backend for a journey step with
`mimic journey step add ... --backend <UUID>` or `mimic journey step update ... --backend <UUID>`;
use `--backend primary` for the original port. Real backend URL and pass-through switches apply immediately. Changes to listening ports require a restart; `server status` reports `restartRequired` and the actual `activeBackends` alongside the configured backends. Mimic listens on `127.0.0.1` only.

Forwarded calls appear in the request log as `passthrough`. To turn one into an editable text mock,
inspect it and run `mimic log save-as-mock <log-UUID>`, or use **Save real response as mock** in
the request log, or **Save response as mock** in the request inspector. Automatic capture is off by default because real replies can contain private data. Credential
response headers are removed from the saved mock; response bodies must be reviewed before sharing
the project. Truncated and binary replies cannot be saved as text mocks.

Name and control each backend without losing its saved URL:

```bash
mimic server configure --name Catalog --upstream https://catalog.example.com
mimic server configure --pass-through false       # pause, retain URL
mimic server configure --pass-through true        # resume
mimic server configure --capture-responses true   # opt in to automatic mocks
mimic server backend update <UUID> --pass-through true --capture-responses true
mimic server configure --file server-settings.json # atomically apply a ServerConfiguration object
```

Automatic capture saves the first complete supported reply per backend, method, path, and GraphQL
operation. Deleting the mock makes the route eligible for capture again when another complete
passed-through response arrives. Capture and live engine updates are asynchronous. Once the captured endpoint
appears in the project, automation can call `mimic state` to await its pending engine update before
checking replay. Pending request delivery
is lossless during bursts, while the visible traffic history retains only its latest 1,000 records.
The pending delivery queue can grow when processing falls behind incoming traffic. Subsequent calls
use the captured mock. Query parameters are forwarded but are not mock match
criteria. Capture removes credential and transport headers; inspect bodies before sharing. Binary,
compressed, oversized (over 5 MiB), and failed responses are never saved as text fixtures.
Cache-only 304 and partial 206/Content-Range replies are refused, as are missing or empty JSON bodies
unless the HTTP method/status deliberately has no body (HEAD, 204, 205). They must not become a mock
that hides a later complete response. For compressed JSON, request `Accept-Encoding: identity` from
the client and capture the uncompressed reply; forwarding does not change this header for you. A
truncated request preview is also refused because it could lose GraphQL operation identity. Binary
and compressed replies are still forwarded byte-for-byte. Large responses and event streams are
forwarded with backpressure. Traffic previews stay at 64 KiB. Complete supported passthrough
responses up to 5 MiB can be captured automatically or with `log save-as-mock`; bodies larger than
the preview are held in private temporary files while their in-process log entry is retained.
The control API returns previews, never temporary-file handles. Saved mocks contain the complete
body and persist normally. Temporary files are released with their last log reference; clearing
traffic or evicting old entries makes unsaved bodies unavailable once no view retains them.
Disk usage can grow with retained large responses; an I/O failure refuses capture rather than
saving a prefix. Abrupt process termination can leave temporary files for OS cleanup. Incoming request
bodies retain the existing 10 MB limit. WebSocket upgrades are not supported. Backend connection
failures appear as `proxyFailure`, separately from real upstream 5xx responses. Redirects are returned
to the client, never followed by Mimic.

Journey export preserves backend UUIDs. Import a journey into a project with the same backends, or
map its `backend` values to that project's IDs before importing; use `primary` for its primary port.

### Projects — whole configurations

```bash
mimic project list
mimic project create "Checkout" [--port 8080]
mimic project open "Checkout"              # switch configurations in one command
mimic project close
mimic project rename "New name"
mimic project duplicate "Checkout"
mimic project delete "Checkout"
mimic project export ["Checkout"] [-o project.json]
mimic project import project.json [--no-activate]
```

Re-importing the same document updates the project in place rather than creating a copy, so a CI step
can import its fixtures on every run.

`project import` takes a **Mimic project document** — what `project export` writes — and nothing else;
handed an OpenAPI or HAR file it fails with "is not a Mimic project document". Spec import has no
command at all, as the top of this page explains.

`project open` refuses a project whose stored document schema is **newer than this build
understands**, with `persistence.failure` and a message naming both version numbers. It is a refusal
rather than a best-effort read because the fields an older build does not know about are exactly the
ones it would drop, and a save afterwards would drop them for good. `project list` still shows it —
a project you cannot open is still a project you have, and hiding it looks like the store having
lost it. Update Mimic, or export from the newer build.

### Endpoints

Addressed by route, so nothing needs a UUID:

```bash
mimic endpoint list
mimic endpoint get GET /account-summary
mimic endpoint create GET /account-summary --status 200 --body '{"balance":10}'
mimic endpoint create POST /login --body-file login.json --header 'X-Trace: abc'
mimic endpoint update GET /account-summary --status 500 --delay 250
mimic endpoint delete GET /account-summary
mimic endpoint duplicate GET /account-summary
```

`--body-file -` reads stdin, which avoids shell quoting problems with large payloads.
`endpoint update --status` edits whichever scenario is active — the one a request would actually get.

### Scenarios — alternative responses per endpoint

```bash
mimic scenario list GET /account-summary
mimic scenario create GET /account-summary "Server error" --status 500 --activate
mimic scenario update GET /account-summary "Server error" --body '{"error":"boom"}'
mimic scenario activate GET /account-summary "Server error"
mimic scenario delete GET /account-summary "Server error"
```

Use a scenario for *"this route always answers X"*; use a journey for *"this route answers X then Y"*.

### Journeys — ordered sequences

See [JOURNEYS.md](JOURNEYS.md) for the model.

```bash
mimic journey templates
mimic journey add-template retry-after-failure --activate

mimic journey list
mimic journey get "Retry after failure"
mimic journey create "Session expiry" --summary "401 then recover"
mimic journey update "Session expiry" --completion restart --no-auto-advance
mimic journey duplicate "Session expiry"
mimic journey delete "Session expiry"

mimic journey activate "Session expiry"    # always starts a fresh run
mimic journey deactivate
mimic journey restart
mimic journey advance                      # retire the current step without serving it
mimic journey status

mimic journey export "Session expiry" -o flows/session-expiry.json
mimic journey import flows/session-expiry.json --replace --activate
```

Steps:

```bash
mimic journey step add "Session expiry" POST /login --status 200 --body '{"token":"t"}'
mimic journey step add "Session expiry" GET /me --status 401 -H 'WWW-Authenticate: Bearer'
mimic journey step add "Session expiry" GET /me --status 200 --at 2
mimic journey step add "Offline" GET /me --fail timeout --hold-ms 5000
mimic journey step add "Offline" GET /me --fail drop --repeat-count 3
mimic journey step update "Session expiry" --index 1 --status 503
mimic journey step move "Session expiry" --index 0 --to 2
mimic journey step remove "Session expiry" --index 1

mimic journey step add-batch "Session expiry" captured.json
mimic journey export "Checkout" | mimic journey step add-batch "Session expiry" - --at 0
```

`step update` changes only the fields you pass: `--status 503` alone keeps the existing body. Passing
`--fail` converts a step to a transport failure; passing a response field converts it back.

`step add-batch` takes the same journey JSON `journey export` writes and **appends** its steps, where
`journey update --file` replaces them. It is one change rather than one per step, so a whole captured
session saves once — which is what the window does when you select several requests in the log and
save them as a journey.

### Request log

```bash
mimic log list [--limit N]
mimic log list --unmatched          # only calls nothing is configured for
mimic log clear
mimic log save-as-mock <log-UUID>
```

Each entry names what answered it — `endpoint`, `journey`, `unmatched`, or `blockedByJourney` — so a
test can assert which part of a flow responded, and `--unmatched` answers *"what is my client calling
that I have not mocked?"* directly:

```
2026-07-30T14:20:22Z  GET   /user/profile        404   Unmatched
2026-07-30T14:20:22Z  POST  /analytics/events    404   Unmatched
```

`unmatched` is not the same as a 404: an endpoint that deliberately returns 404 is `endpoint`, and a
request a journey answered is `journey`. Only `unmatched` means the configuration is missing.

Entries also carry the response — `responseStatusCode`, `responseHeaders`, and `responseBody` (capped
at 64 KB, with `responseBodyTruncated` when it was cut) — so a script can assert on what the client
actually received. A failed request is logged as a failure with no status code, rather than a
fabricated one.

## A complete agent workflow

```bash
set -e
export MIMIC_DATABASE_PATH="$PWD/.mimic-ci/store.sqlite"   # isolated store

mimic daemon start
mimic project create "CI" --port 8080
mimic endpoint create GET /settings --status 200 --body '{"theme":"dark"}'
mimic journey add-template retry-after-failure --activate
mimic server start

# … run the app under test against http://127.0.0.1:8080 …

mimic journey status --format text
mimic log list --limit 20 --format text
mimic app stop
```

Between test cases:

```bash
mimic journey activate "Payment retry"   # switch scenario
mimic reset --scope all                  # rewind the journey, clear the log
```

## Talking to the API directly

The CLI is a thin client over a loopback HTTP API, so a non-Swift agent can skip it. Every request
needs the instance's token in an `X-Mimic-Token` header — read it from the discovery file the running
instance writes:

```bash
# The installed app is sandboxed, so its Application Support is inside its container. An unsandboxed
# build writes to ~/Library/Application Support/devxa.Mimic/control.json instead; the CLI looks in
# both, in that order, which is why it needs no configuration.
CONTROL=~/Library/Containers/devxa.Mimic/Data/Library/Application\ Support/devxa.Mimic/control.json
TOKEN=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' < "$CONTROL")

curl -s -H "X-Mimic-Token: $TOKEN" http://127.0.0.1:8787/v1/state
curl -s -H "X-Mimic-Token: $TOKEN" http://127.0.0.1:8787/v1/commands
curl -s -X POST http://127.0.0.1:8787/v1/command \
  -H "X-Mimic-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"journeyActivate":{"journey":{"name":"Retry after failure"}}}'
```

A sandboxed app writes its file inside its container instead — see the paths in
[SECURITY.md](../SECURITY.md). Setting `MIMIC_CONTROL_TOKEN` on both the instance and the caller works
too, and is the usual arrangement in CI.

Commands encode as a single-key object named after the operation, with labelled parameters:

```json
{ "serverStop": {} }
{ "endpointCreate": { "method": "POST", "path": "/login", "name": "Login" } }
{ "journeyStepAdd": { "journey": { "name": "Offline" },
                      "step": { "method": "GET", "path": "/me",
                                "failure": { "timeout": { "holdMs": 5000 } } } } }
```

**This is where the envelope lives.** Every route answers in one of two shapes — `health` and a
refusal included — so a caller branches on a single boolean and never has to guess whether the
payload is an error:

```json
{ "ok": true,  "result": { "journeyStatus": { … } } }
{ "ok": false, "error":  { "code": "journey.notFound", "message": "…" } }
```

Error codes also map onto HTTP statuses (`401` missing or wrong token, `403` browser-shaped request,
`404` not found, `400` bad request, `409` precondition not met), so `curl --fail` behaves sensibly
without parsing JSON. The refusal still arrives as an envelope with the code in it, which names the
problem far better than the status number does.

The control API binds `127.0.0.1` only, never the interface the app under test can route to, and
requires a per-instance token on every route. Loopback alone is not the boundary — a web page can
reach a loopback port, so the token and the `Origin`/`Host` checks are what actually keep one out.
[SECURITY.md](../SECURITY.md) has the details.

## Design notes

- **The CLI hosts nothing.** No server, no database. Every invocation reads and writes the one live
  instance, so two commands a second apart cannot disagree about the world — and `mimic` stays a
  small static binary that links neither Vapor nor GRDB. That last clause is checked rather than
  asserted: [`Scripts/check_module_edges.py`](../Scripts/check_module_edges.py) walks both manifests
  on every CI run and fails if `MimicCLICore` or the `mimic` executable can reach Vapor, GRDB or
  `SpecImport` by any path — including through a target that acquires one of them later.
- **One implementation of the rules.** Project-scoped commands are applied by `ProjectCommandExecutor`
  in the `Domain` module, which the CLI, the HTTP API, and the app window all call. A rule can only be
  written once, so the window and the script cannot drift.
- **Operations are data.** A command is a value (`ControlCommand`), which is what makes it replayable,
  diffable, and self-describing.

### Journey groups

`mimic journey create "Payment retry" --group Checkout` assigns a navigator group.
Use `mimic journey update "Payment retry" --group Payments` to move it, or `--group ""`
to leave it ungrouped. Journey JSON uses `groupTag`; omitting it on update preserves the group.
