# CLI and control API

`mimic` drives the running macOS app, including its headless mode. Use `mimic commands` to inspect the operations the current instance accepts and `mimic --help` for exact flags. The CLI prints a result JSON object on stdout, one diagnostic line on stderr after a failure, and no JSON envelope. Add `--format text` for display output.

HAR and OpenAPI/Swagger spec import require the window. `mimic project import` accepts only a JSON document written by `mimic project export`. `mimic app update-check` is available to scripts; installing an update requires the window and macOS Installer.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Command succeeded. |
| `2` | Bad arguments or an unreadable input file. |
| `3` | No usable Mimic instance or app to launch or stop. |
| `4` | Mimic refused the command or returned an unreadable result. |

For code `4`, stderr starts with a stable dotted error code such as `endpoint.notFound` or `server.portInUse`. The CLI result is already unwrapped: `mimic journey status | jq -e '.journeyStatus.isComplete'`.

## Starting and stopping

```bash
mimic app start                 # waits for the control API to answer
mimic app start --headless
mimic daemon start              # same app, without a window
mimic app status
mimic app stop                  # verifies the instance PID before SIGTERM
mimic app update-check          # returns updateAvailable; does not install
```

`MIMIC_APP_PATH` selects a noninstalled app bundle. A headless run still requires `Mimic.app`; it uses the same `AppControlHost` as a visible run. `app stop` signals only the instance named by the discovery file after confirming its PID and ignores `--url` for that reason. If confirmation fails, stop the process manually after verifying it.
`app start --wait-seconds` accepts a finite value greater than zero and at most 3600; invalid values fail before the app launches.

## Finding an instance

For a command destination, the CLI checks `--url`, then `MIMIC_CONTROL_URL`, then `MIMIC_CONTROL_PORT` on loopback, then the discovery file. It skips stale discovery files. A token read from that file is sent only to a loopback host on the exact advertised port. Supply `MIMIC_CONTROL_TOKEN` explicitly for a forwarded or remote destination.

| Variable | Purpose |
| --- | --- |
| `MIMIC_CONTROL_URL` | Explicit control API base URL. |
| `MIMIC_CONTROL_PORT` | Loopback control port; default `8787`. |
| `MIMIC_CONTROL_TOKEN` | Explicit token for both instance and caller when discovery is unavailable. |
| `MIMIC_CONTROL_FILE` | Discovery file path used by both instance and CLI; overrides default search. |
| `MIMIC_DATABASE_PATH` | Project SQLite path. |
| `MIMIC_APP_PATH` | App bundle to launch. |

The discovery file contains the instance's port, PID, and token. It is written `0600`, with a `0700` parent directory. Set the path variables before starting the app. A signed app is sandboxed and cannot write arbitrary temporary paths outside its container; the [end-to-end harness](../Scripts/run_cli_e2e.sh) uses a disposable ad hoc signed app copy for this purpose. Choose a nondefault `MIMIC_CONTROL_PORT` if another local instance may be running, and use a fresh token for each run.
The control client refuses HTTP redirects so a listener cannot forward a token to another host or port after the initial destination check.

Shutdown removes the discovery file only when it still contains this instance's record. Publication and cleanup use the same lock, so another instance cannot replace the record between that check and removal. A failed bind has no record to remove, and cleanup leaves an already replaced record alone. The default path advertises one instance at a time; give concurrent runs separate `MIMIC_CONTROL_FILE` paths.

## Command reference

The examples show common forms; `mimic <group> <verb> --help` gives all options.

### Instance and server

```bash
mimic ping
mimic state
mimic commands
mimic reset --scope logs|journey|all
mimic server start [--port N]
mimic server stop
mimic server status
mimic server configure [--port N] [--delay MS] [--upstream URL]
mimic server configure --disable-upstream
mimic server configure --name Catalog --pass-through true
mimic server configure --capture-responses true
mimic server configure --file server-settings.json
mimic server backend add --name Accounts --port 8081 --upstream URL
mimic server backend update <UUID> [--name NAME] [--port N] [--upstream URL]
mimic server backend delete <UUID>
```

One project can listen on several local ports. The original port is the primary backend; additional backends have stable UUIDs. Select a backend for an endpoint or journey step with `--backend <UUID>` or `--backend primary`. A journey step resolves first, then an endpoint on that backend, then an enabled upstream. An explicit journey block is not forwarded. Port edits require a restart; `server status` reports `restartRequired` and both configured and active backends. Upstream and pass-through switches apply live.

Forwarded calls are logged as `passthrough`. `mimic log save-as-mock <log-UUID>` saves a complete supported text response. Automatic capture is opt-in with `--capture-responses true` and saves the first complete reply for a backend, method, path, and GraphQL operation. It skips binary, compressed, truncated, failed, cache-only `304`, partial `206`, and unexpectedly empty JSON responses. Request `Accept-Encoding: identity` to capture an uncompressed JSON reply. Previews are limited to 64 KiB; complete supported responses up to 5 MiB can be saved. Review bodies before sharing projects. Large and event-stream responses pass through without becoming mocks; WebSocket upgrades are unsupported.

Capture and engine updates are asynchronous. Poll `mimic state` for the pending engine update to clear before asserting that a newly captured mock is serving.

### Projects

```bash
mimic project list
mimic project create "Checkout" --port 8080
mimic project open "Checkout"
mimic project close
mimic project rename "New name"
mimic project duplicate "Checkout"
mimic project delete "Checkout"
mimic project export ["Checkout"] -o project.json
mimic project import project.json [--no-activate]
```

Reimporting the same project document updates it in place. A stored project written by a newer schema remains listed but cannot be opened by an older build; update Mimic or export it from the newer version.

### Endpoints and scenarios

```bash
mimic endpoint list
mimic endpoint get GET /account-summary
mimic endpoint create GET /account-summary --status 200 --body '{"balance":10}'
mimic endpoint create POST /login --body-file login.json --header 'X-Trace: abc'
mimic endpoint update GET /account-summary --status 500 --delay 250
mimic endpoint duplicate GET /account-summary
mimic endpoint delete GET /account-summary

mimic scenario list GET /account-summary
mimic scenario create GET /account-summary "Server error" --status 500 --activate
mimic scenario update GET /account-summary "Server error" --body '{"error":"boom"}'
mimic scenario activate GET /account-summary "Server error"
mimic scenario delete GET /account-summary "Server error"
```

`--body-file -` reads stdin. `endpoint update --status` changes the active scenario. A scenario selects a standing response; a journey scripts a sequence.
Endpoint edits require a unique match. If multiple backends contain the same method and path, select the endpoint by UUID with `--id`.
Scenario create, update, activate, and delete also accept `--id <endpoint-UUID> <scenario-name>` when an endpoint route is shared.

### Journeys

See [Journeys](JOURNEYS.md) for matching and progression.

```bash
mimic journey templates
mimic journey add-template retry-after-failure --activate
mimic journey list
mimic journey get "Retry after failure"
mimic journey create "Session expiry" --group Checkout
mimic journey update "Session expiry" --completion restart --no-auto-advance
mimic journey duplicate "Session expiry"
mimic journey delete "Session expiry"
mimic journey activate "Session expiry"
mimic journey deactivate
mimic journey restart
mimic journey advance
mimic journey status
mimic journey export "Session expiry" -o flow.json
mimic journey import flow.json --replace --activate

mimic journey step add "Session expiry" POST /login --status 200
mimic journey step add "Session expiry" GET /me --fail timeout --hold-ms 5000
mimic journey step update "Session expiry" --index 1 --status 503
mimic journey step move "Session expiry" --index 0 --to 2
mimic journey step remove "Session expiry" --index 1
mimic journey step add-batch "Session expiry" flow.json
```

`step update` changes only supplied fields. `step add-batch` appends the exported journey's steps in one project update; `journey update --file` replaces them. Journey exports retain backend UUIDs, which must exist or be mapped in the importing project.
`journey import` creates only when lookup returns `journey.notFound`; `--replace` updates the looked-up journey ID, and `--activate` uses the ID returned by the write.

### Request log

```bash
mimic log list [--limit N]
mimic log list --unmatched
mimic log save-as-mock <log-UUID>
mimic log clear
```

Each entry identifies the outcome (`endpoint`, `journey`, `passthrough`, `unmatched`, or `blockedByJourney`) and includes response status, headers, and a capped body preview. An intentional endpoint `404` is not `unmatched`. A transport failure has no fabricated status code.

## A disposable test run

After building the Debug app and CLI into `.artifacts/DerivedData` (see [Contributing](../CONTRIBUTING.md)), run the repository harness:

```bash
products="$PWD/.artifacts/DerivedData/Build/Products/Debug"
MIMIC_BIN="$products/mimic" MIMIC_APP_PATH="$products/Mimic.app" ./Scripts/run_cli_e2e.sh
```

## Calling the HTTP API

The control API listens only on loopback. Read the token from the current instance's discovery file; the sandboxed app normally writes under `~/Library/Containers/devxa.Mimic/Data/Library/Application Support/devxa.Mimic/`, while an unsandboxed build uses `~/Library/Application Support/devxa.Mimic/`. `MIMIC_CONTROL_FILE` overrides both.

```bash
CONTROL="$HOME/Library/Containers/devxa.Mimic/Data/Library/Application Support/devxa.Mimic/control.json"
TOKEN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' < "$CONTROL")
curl -H "X-Mimic-Token: $TOKEN" http://127.0.0.1:8787/v1/commands
curl -X POST http://127.0.0.1:8787/v1/command \
  -H "X-Mimic-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"serverStop":{}}'
```

`POST /v1/command` accepts a single-key object named for a `ControlCommand` case. Every route, including health, returns an envelope: `{"ok":true,"result":{…}}` or `{"ok":false,"error":{"code":"…","message":"…"}}`. HTTP statuses distinguish bad requests, missing resources, conflicts, and authentication failures; scripts should also read `error.code`. See [Security](../SECURITY.md) for token and browser protections.
