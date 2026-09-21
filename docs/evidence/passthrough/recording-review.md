# Concurrent recording and backend toolbar review

21 September 2026. Synthetic local traffic plus live Google DNS JSON requests; development-build evidence.

## Findings and changes

- **Lost captures under load:** the engine used a `bufferingNewest(1000)` delivery queue for both
  traffic display and automatic capture. A stalled consumer discarded old requests before capture
  could inspect them. The regression sent 1,100 requests plus a terminating marker and retained only
  999 request records before the fix. Delivery now preserves pending records; the runtime still
  retains only 1,000 processed records for display. Pending delivery memory can grow while a
  consumer falls behind. This is not an indefinite-overload or bounded-memory guarantee.
- **Deleted routes:** no permanent capture tombstone exists. Duplicate prevention checks the current
  project's endpoints. Repeated deletion and re-capture succeeded on both listeners, including
  immediate requests after the delete command. A captured endpoint becomes visible before its
  asynchronous engine push completes; the replay assertions explicitly await that push through
  `state`. Client-side caching can prevent a request from reaching Mimic and is not covered here.
- **Hidden additional ports:** the toolbar now has a port-count button and popover, named configured ports,
  copyable running URLs, and a restart-required distinction when configured listeners differ from
  those actually bound. Live name changes retain the bound port.
- **Moving toolbar click targets:** `EmptyView` discarded the reserved autosave frame when the
  saved indicator cleared. A transparent idle view preserves that space and stops the native
  principal toolbar item recentering during a click. The stopped-state interaction test reproduced
  this miss and passed after the geometry fix.

## Automated and live coverage

| Scenario | Evidence |
| --- | --- |
| Delivery above the old 1,000-event cap | Deterministic burst regression; negative control failed on the old implementation |
| 1,100 automatic captures | Runtime/app test verifies distinct endpoints and repository save/load while visible traffic remains at 1,000 |
| Parallel requests on two ports | 200 distinct captures; identical paths retain each backend's response |
| Delete and record again | Three capture/delete cycles on each backend; fresh response followed by mock replay |
| Unsupported text captures | Binary, gzip, and 70 KB replies forward without being saved as text mocks |
| Real HTTP errors and empty replies | Upstream 503 and empty 204 become mocks with their actual status |
| GraphQL | Two operations on each of two backends remain four distinct endpoints |
| Query strings | Forwarded intact; saved routes deliberately match without the query |
| Live settings | Changing upstream, disabling forwarding, and disabling/re-enabling capture |
| Port conflict | Secondary bind failure releases the primary listener; both start after correction |
| Persistence | 210 endpoints survive close/open, process quit/relaunch, and reopen in an isolated SQLite store |
| Stopped toolbar | Port count, named configured ports, settings validation and retained values |
| Running and compact toolbar | Both controls remain hittable; secondary URL copies correctly; old/new ports and restart state are distinguished |
| Autosave | Saved indication clears without moving the port controls |
| Existing HTTP regression harness | Nine checks pass: exact bytes, repeated cookies, hop headers, streaming, GraphQL, capture, journeys, failures, runtime packaging |

The persistence check used the normal sandboxed app with unique app-container database, defaults,
and discovery paths, and verified a new process could reload the project. No developer database
was opened or reset by the integration harness. Process logs in `/tmp` are not themselves proof
of persistence; the close/relaunch/reopen assertions are.

The existing temporary security-audit tests were preserved. The first engine sweep
crashed with a Vapor teardown assertion immediately after the temporary audit class ran. A rerun
excluding that pre-existing untracked class yielded 75 passing engine tests; the precise cause of
the temporary-suite teardown crash was not established. The 61 selected app/toolbar unit tests also passed. The three backend-settings UI tests passed,
followed by the compact-window extension and the existing autosave UI regression. The final engine
sweep includes 1,100 real forwarded responses, not just locally generated unmatched requests.

## Reproduce

```sh
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -only-testing:MockServerEngineTests \
  -skip-testing:MockServerEngineTests/SecurityAuditTemporaryTests \
  -only-testing:MimicTests/AppStateAndViewTests -only-testing:MimicTests/ServerStatusWellTests

python3 docs/evidence/passthrough/recording_review.py \
  --app /path/to/Mimic.app/Contents/MacOS/Mimic

xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
  -destination 'platform=macOS' -only-testing:MimicUITests/BackendSettingsUITests
```

Run native app checks serially. Do not launch a second copy of the same app bundle during XCUITests.

House rules, module boundaries, lockfile parity, and UI shard coverage pass. Compiler-settings checks
retain their existing warnings about SwiftPM settings. Documentation counts pass for a copy of the
tracked source tree (1,315 declarations); the untouched temporary audit files add four local-only
declarations and therefore make the direct working-tree count differ. No full CI, Linux, Release,
notarization, installed-app upgrade, or indefinite-load qualification is claimed.

The existing `Scripts/test_passthrough_e2e.py` also passed all nine checks. That companion harness
uses its documented test-only ad-hoc-signed copy without sandbox entitlements; the 210-endpoint
persistence and multi-backend burst check above uses the normal sandboxed build. First streaming
bytes arrived in 0.001 seconds, before the fixture's deliberately delayed second chunk.

The final configured-port UI assertion passed with literal, ungrouped port numbers.
[Verified configured-port popover](ports-configured.png) shows the actual app window and synthetic
fixture. Screenshots containing other applications were kept out of repository evidence.

Final result bundles (local):

- App units, engine units, compact ports and autosave: `Test-Mimic-Workspace-2026.09.21_18-22-19-+0100.xcresult`
- Final configured-port wording and interaction: `Test-Mimic-Workspace-2026.09.21_18-27-27-+0100.xcresult`
- Full backend settings UI suite: `Test-Mimic-2026.09.21_18-19-29-+0100.xcresult`

These are under the workspace's current Xcode DerivedData `Logs/Test` directory. The changes are
local on `codex/passthrough-recording-review`; no release or installation was performed.

## Empty / `1` / compressed JSON follow-up

A live isolated-store reproduction against the previous build saved an HTTP 304 as an empty JSON
scenario. Such a cache validator tells the client to reuse its cached representation; it does not
contain the full body the client displays. Once captured, the empty route blocked later capture.
The pre-fix failure is in `/tmp/mimic-json-before.log`.

The shared capture boundary now rejects 304, 206/Content-Range fragments, and unexpectedly empty or
missing JSON bodies. HEAD, 204 and 205 remain intentionally bodyless; complete scalar JSON (`1`,
`true`, `false`, `null`, strings) remains unchanged. A synthetic 206 containing only `1` demonstrates
another way an incomplete representation could previously be saved. This does not establish that
it caused the user's particular observation; a blank editor also displays gutter line number 1.
No object-to-number conversion was found in the capture path.

Compression is a separate supported-forwarding/unsupported-capture case: gzip bytes are not UTF-8,
even when the decoded content is JSON. The capture refusal now explains compression before testing
UTF-8 and suggests requesting `Accept-Encoding: identity`. We have not added decompression or
changed forwarded bytes/headers. Binary, oversized and incomplete replies remain uncapturable.

Validation:

- Full Domain run: 299 tests passed. Focused run: 8 capture-rule tests, 46 app/state tests,
  5 passthrough-engine tests passed. House rules, tracked-source documentation counts, Python lint
  and diff whitespace checks also passed.
- Normal sandbox harness: 304, 206 containing `1`, and empty JSON are forwarded but not captured;
  a subsequent complete response captures and replays correctly for all three routes.
- 16 simultaneous JSON responses across both listeners (objects, arrays, booleans, null, numeric
  and string scalars, Unicode) retain exact stored and replayed bodies.
- Live Google DNS JSON over HTTPS at `https://dns.google.com/resolve?name=example.com&type=A`:
  three capture/delete/recapture cycles on each listener passed. All six saved/replayed replies
  matched the respective upstream response byte-for-byte (254–297 bytes in the final run).
- Google gzip on both listeners: valid JSON after decompression, 160 wire bytes in this run;
  automatic capture correctly skipped it and explicit capture returned the compression guidance.
- 232 synthetic fixtures survived close, quit, relaunch and reopen after the expanded test run.
- TLS verification stayed enabled. `dns.google` failed TLS from this machine; the
  `dns.google.com` endpoint succeeded. No claim that all upstream TLS configurations work.

Repeat with `recording_review.py --live-google --app /absolute/path/to/Mimic.app/Contents/MacOS/Mimic`.
The flag makes eight requests to Google's public API (six uncompressed, two gzip); other traffic is
loopback-only. Google's [JSON API documentation](https://developers.google.com/speed/public-dns/docs/doh/json)
describes the request and response. No project data or credentials are sent to Google.
Final harness log: `/tmp/mimic-json-google-final.log`; isolated process log:
`/tmp/passthrough-review-3apibt64/app.log`. These are local evidence paths, not committed artifacts.

## Independent public API cross-check

JSONPlaceholder (`https://jsonplaceholder.typicode.com`, [official guide](https://jsonplaceholder.typicode.com/guide/))
passed through both listeners with TLS verification enabled and `Accept-Encoding: identity`.
Eight requests ran with concurrency four: `/posts/1`, `/todos/1`, `/users/1`, and `/posts?userId=1`
on each listener. JSON objects, a boolean field, nested objects, and an array retained exact captured
and replayed bytes (83–2,726 bytes). Deleting `/posts/1` and recapturing also passed on both listeners.
Ten public GET requests total; all replay checks were served by Mimic. No API credentials or user
data were sent. The expanded run persisted 240 fixtures across quit/relaunch/reopen.

Repeat using `recording_review.py --live-jsonplaceholder --app /absolute/path/to/Mimic.app/Contents/MacOS/Mimic`.
Evidence: `/tmp/mimic-jsonplaceholder.log`, `/tmp/passthrough-review-36fk7tpt/app.log`.
Python lint and diff whitespace checks passed. This step changes only the opt-in verification
harness and evidence, not production code; the app/unit suites were not repeated.

## Two different internet backends called concurrently

`--live-mixed` configures the primary Mimic listener for `https://dns.google.com` and the secondary
for `https://jsonplaceholder.typicode.com`. Three rounds each synchronize four client requests with
a barrier: Google `/resolve?name=example.com&type=A` plus JSONPlaceholder `/posts/1`, `/todos/1`,
and `/users/1`. All four calls started before any completed in each round, with measured overlap of
60 ms, 13 ms, and 16 ms. This is 12 real upstream GET requests with TLS verification enabled and
`Accept-Encoding: identity`; it is a bounded concurrency check, not an internet load test.

All passed: valid complete JSON, backend-specific passthrough logs, exact saved response bodies,
parallel mock replay, deletion and recapture between rounds, and exact bodies after app relaunch.
236 total fixtures survived the expanded isolated-store run. No cross-backend response mix-up,
missing capture, or unexpected empty/`1` body appeared. No production code changes were necessary.

Repeat: `recording_review.py --live-mixed --app /absolute/path/to/Mimic.app/Contents/MacOS/Mimic`.
Evidence: `/tmp/mimic-mixed-live.log`, `/tmp/passthrough-review-d9sftxib/app.log`.
Python lint and diff whitespace checks passed.
