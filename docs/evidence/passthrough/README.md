# Pass-through implementation review and verification

19 September 2026. Evidence uses synthetic local fixtures, never customer traffic.

## Review fixes

| Finding | Implemented correction |
| --- | --- |
| Binary capture changed bytes | Forward raw bytes; reject binary, non-UTF-8 and compressed capture |
| Cookies were combined | Preserve repeated headers using AsyncHTTPClient; strip Connection-nominated hop headers |
| Every response was buffered | Stream with backpressure, reuse the app's HTTP client, cap log previews at 64 KiB |
| Captured GraphQL intercepted other operations | Preserve operation identity in mocks and journeys |
| Journey capture could retain credentials or partial bodies | One shared capture policy for mocks and journeys |
| Disabled forwarding continued until restart | Read current backend configuration on each request; control replies await configuration delivery |
| Connection failures became reusable mocks | Distinct `proxyFailure`; never capture incomplete responses |
| Journey export dropped backend ownership | Export `backend` in response and network-failure steps |
| Secondary requests copied the wrong curl port | Snapshot the actual listener port, backend, upstream and duration in each log |
| Retry changed the primary port for secondary conflicts | Change the conflicting listener and skip other configured ports |
| Corrupt backend JSON silently became an empty list | Refuse malformed persisted configuration |
| UI mixed partial saves and silently lost edits | Atomic draft with Apply/Cancel, field validation, named primary backend, URL copy, persistent pass-through switch |
| No automatic endpoint creation | Explicit per-backend opt-in; capture first supported response, then serve the mock; prevent duplicate and cross-project capture |
| Selecting binary traffic could crash the inspector | Keep wrapped capture guidance inside the scrollable region |
| Inspector values were missing from accessibility | Provide explicit label/value accessibility representations |
| Narrow traffic table extended under adjacent panels | Compact toolbar and horizontally scrollable aligned columns |
| Settings UI suite was absent from CI | Register suite in a shard and add real HTTP/CLI integration gate |

## Verified locally

- 727 portable test declarations passed (`swift test`), including real listener isolation, live pause, header forwarding, capture safety, CLI command encoding, persistence, and project validation.
- 333 app test declarations passed (xcresult summary), including GraphQL capture, automatic capture ownership/deduplication, and secondary-port recovery.
- Three focused XCUITests passed together (`/tmp/mimic-final-ui.xcresult`): configure two listeners, reject duplicate ports, persist changes, cancel a draft, pause while retaining the URL, refuse binary capture, save a text reply, and serve it after forwarding is disabled. The inspector flow also checks backend accessibility and the narrow table’s leading column.
- Final Release build passed (ad-hoc signing, Xcode beta, macOS 26 deployment target).
- Repository gates passed: module boundaries, lockfile parity, house rules, UI shard coverage and documentation counts.
- [Nine live HTTP checks](live-http.txt): exact binary and gzip bytes, separate cookies, 100 KB reply with bounded capture, streaming before completion, GraphQL isolation, automatic capture, mixed-backend journey export, uncapturable connection failures, and no duplicate runtime classes.
- UI inspected in the running macOS app and real XCUITest screenshots: [server settings](settings.png) and [request inspector](inspector.png). Screenshots contain synthetic fixture data only; the inspector image includes the test runner’s pointer overlay.

The Python integration harness creates an ad-hoc signed **development copy without sandbox entitlements** so its child and CLI can share a disposable temporary store. It does not alter the supplied app. The XCUITests use the normally signed, sandboxed build. This distinction matters: the HTTP evidence verifies the real app/CLI/runtime seam, not distribution signing or notarization.

## Reproduce

```sh
python3 Scripts/test_passthrough_e2e.py --app /path/to/Mimic.app --cli /path/to/mimic
```

Build with the workspace, and use the app and CLI from the same build. Unit/UI result bundles were kept locally under `/tmp/mimic-fix-final-*` during this run. Build and CI status are recorded in PR #77.

## Explicit limits

Capture supports complete UTF-8 text replies up to 64 KiB, with a complete request preview so GraphQL identity cannot be lost. Other replies still pass through unchanged. Uploaded bodies retain the existing 10 MB limit. WebSocket upgrades are unsupported. Mock matching uses backend, method, path and GraphQL operation; it does not distinguish query parameter values. Response bodies can contain private data and should be reviewed before sharing a project. Automatic capture is off by default.
