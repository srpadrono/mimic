# Release regression gate

Every release is checked by hand against the build that ships, after CI is green and before the
GitHub release is published. Each scenario below is recorded as a screen video, and the videos are
attached to the release as evidence. A release does not go out while a core scenario fails: fix it,
or leave the release as a draft and report what failed.

CI already proves the parts it can reach (unit suites, the UI shards, the layout audit, gallery
snapshots and the CLI end-to-end harness). This gate covers what CI cannot: the signed Release
build, on a real display, with a real pointer, going through the flows a person uses.

## Setup

1. Quit your own Mimic (⌘Q). The gate uses ports 8080, 8081 and 18099 and control port 47391.
2. Update the checkout and build the release with signing, as [Contributing](../CONTRIBUTING.md#releases)
   describes. `Scripts/package_release.sh` leaves the built products in
   `.artifacts/package/DerivedData/Build/Products/Release`.
3. Start the build under test in its own store:

   ```bash
   Scripts/release_regression.sh start --fresh \
     .artifacts/package/DerivedData/Build/Products/Release/Mimic.app \
     .artifacts/package/DerivedData/Build/Products/Release/mimic
   ```

   It runs a copy of the release app with its own store, defaults and discovery file under
   `~/MimicRegression/<version>`, so the gate never opens your projects. Open a Terminal window
   beside the app and `source ~/MimicRegression/<version>/env.sh` in it; the curl and `mimic` steps
   run there.
4. Grant Screen Recording to whatever runs `screencapture` (System Settings ▸ Privacy & Security).

## Recording

Record each scenario on its own, with the app and the Terminal both on screen:

```bash
cd ~/MimicRegression/<version>/videos
screencapture -v -k R03-first-endpoint.mov &   # -k shows clicks
# … run the scenario …
kill -INT %1                                  # ends and writes the file
```

Name each file `R<number>-<slug>.mov`. When every scenario is recorded, compress them for upload:

```bash
for f in R*.mov; do avconvert --preset Preset1920x1080 --source "$f" --output "${f%.mov}.mp4" --replace; done
```

Write down the result of each scenario (pass, or what went wrong) as you go; the release notes carry
the table. Fixtures live in [release-regression/fixtures](release-regression/fixtures).

## Scenarios

Each scenario starts where the previous one left off unless it says otherwise. "Expect" lines are
what the video has to show for the scenario to pass.

### R01 Launch and welcome

Start from `--fresh`. The welcome window opens.
- Expect: the window shows the release's version ("Version X.Y.Z"), New project, the sample
  project, import, and open-export choices, and no recent projects.

### R02 Sample project

Open the sample project from the welcome window.
- Expect: the workspace opens on "Sample project" with four endpoints (`POST /login`,
  `GET /account-summary`, `GET /inbox`, `GET /products/:id`) and one journey.
- Select each endpoint in turn: the editor shows its live scenario's status and body.

### R03 First endpoint and live traffic

With File ▸ New Project…, create a project "Regression" on port 8081.
Add endpoint `GET /health`, status 200, body `{"ok":true}`. Start the server from the toolbar.
In Terminal: `curl -i http://127.0.0.1:8081/health`.
- Expect: the new-project sheet says the port is available; the toolbar shows the server running;
  curl prints `200` and `{"ok":true}`; the request log shows the call matched to `/health`.

### R04 Edit a response while serving

With the server running, change `/health` to status 503 and body `{"ok":false,"reason":"maintenance"}`.
Press Format. Undo once and redo once. Curl again.
- Expect: Format indents the JSON; undo and redo restore each version; curl prints `503` and the new
  body without a server restart.

### R05 Scenarios

Add a scenario "Healthy" to `/health` (200, `{"ok":true}`) and make it live. Curl. Make the 503
scenario live again. Curl.
- Expect: each curl returns the scenario that was live when it was sent.

### R06 Route parameters

Switch to the sample project and start its server.
`curl -i http://127.0.0.1:8080/products/42` and `curl -i http://127.0.0.1:8080/products/abc`.
Make "Not found" live and curl again.
- Expect: both paths match `/products/:id` with 200 and the lamp body, then 404 `{"error":"not_found"}`.

### R07 Request log and request detail

Curl `http://127.0.0.1:8080/inbox` and an unmatched `http://127.0.0.1:8080/orders`. Select each
row in the request log. Open the Request, Response and Timing tabs. Use Copy as cURL and paste it
into Terminal. On the unmatched row choose Create endpoint.
- Expect: the detail opens beside the log with headers and query items; the pasted cURL command
  runs; the unmatched row offers Create endpoint, which opens the new endpoint for `GET /orders`
  and the next curl to `/orders` matches it.

### R08 Journeys

Open Journeys. Activate the sample's retry journey (or add "Retry after failure" from a template
and activate it). Curl `/account-summary` twice. Click the "Active" badge to end the run.
- Expect: the first call returns the failure step, the second the success step; the journey shows
  its position advancing; ending the run returns `/account-summary` to its live scenario.

### R09 Journey editing

Create a new empty journey "Checkout", add two steps for `/inbox` (status 200, then 204) through
the step sheet, give it a group, and activate it. Curl `/inbox` twice, then deactivate.
- Expect: the step sheet saves each step; the navigator files the journey under its group; the
  curls follow the steps in order.

### R10 Server settings and listeners

Open Server settings. Add a second port 8082 and apply. Curl `/health` on 8081 and 8082 in the
Regression project. Try to add a port that is in use (8080 while the sample serves it).
- Expect: settings say which ports are available; both listeners answer; the in-use port is
  reported before it is applied.

### R11 Forwarding and capture

In Terminal: `cd docs/release-regression/fixtures && python3 -m http.server 18099`.
In Server settings, set the 8082 listener's upstream to `http://127.0.0.1:18099` and its
"When unmatched" to forward. Curl `http://127.0.0.1:8082/upstream-status.json`. In the request
log, save that response as a mock. Stop the Python server and curl again.
- Expect: the first call is forwarded and shows `{"source":"upstream","version":1}`; the saved mock
  appears as an endpoint; the last call is answered by the mock with the upstream down.

### R12 OpenAPI import

Import `docs/release-regression/fixtures/storefront-openapi.json` into a new project from the
welcome window or the toolbar's Import.
- Expect: the review sheet lists `GET /products`, `GET /products/{id}` (as a route parameter) and
  `POST /orders` with their example bodies; importing creates those endpoints.

### R13 HAR import

Import `docs/release-regression/fixtures/storefront.har` into the same project.
- Expect: the review shows the file name and two hosts; the second `GET /v1/cart` is marked as a
  duplicate of the first; the host menu hides `cdn.storefront.example`'s row; importing creates
  only the selected rows. Preview a body from the row under the pointer.

### R14 Export and reopen

In Terminal: `mimic project export "Regression" -o ~/MimicRegression/regression-export.json`. In the app, File ▸ Open Project Export… (⌘O) and open it.
- Expect: the export is validated and opens as a project with the same endpoints and scenarios.

### R15 CLI drives the open window

In Terminal: `mimic --version`, `mimic state`, then
`mimic endpoint create GET /from-cli --status 200 --body '{"via":"cli"}'` and curl it.
- Expect: the CLI reports the release's version and control API; the new endpoint appears in the
  window without a reload; curl returns its body.

### R16 Persistence across relaunch

Quit with ⌘Q right after an edit (rename an endpoint). Run `Scripts/release_regression.sh start`
again without `--fresh`.
- Expect: every project, endpoint, scenario, journey and the rename are there after relaunch.

### R17 Window, panels and appearance

Hide and show the navigator, inspector and request log. Drag the window to its narrowest, then to
full screen. Switch Endpoints and Journeys. Switch macOS between light and dark appearance.
- Expect: no clipped or overlapping controls; the toolbar folds into one menu when narrow; the
  inspector steps aside before the editor is squeezed; both appearances are legible.

### R18 Updates

Mimic ▸ Check for Updates…, then `mimic app update-check`.
- Expect: before the release is published both say this version is current (or offer only a
  newer published version); nothing is downloaded or installed.

## Publishing the evidence

Upload the `.mp4` files as assets of the release, and add a table to the release notes with one
row per scenario: its number, title, result, and the asset name. Keep failed scenarios in the table
with what failed; a failed core flow keeps the release a draft.
