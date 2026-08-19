# Performance baseline

Captured before the redesign's log work (#24, #34) so the "after" has something to be compared with.

## What is measured, and what is not

The log pipeline's real cost is not in the row. Every served request mutates one `@Observable` array
on the main actor, which re-evaluates `WorkspaceView.body` and takes four O(n) scans with it, then
rebuilds `tableBody` with three more whole-log allocations. That is view work in `AppFeatures`, which
is **not** in `Package.swift` — measuring it needs the Xcode test runner and Instruments.

What is captured here is the part that is a pure rule: `RequestLogFilter`, which every one of those
scans ultimately calls. It is deterministic, windowless, and runs under `swift test` — which matters
on this machine, where `xcodebuild test` frequently cannot run at all.

## The buffer is 1,000, not 10,000

Worth stating because the redesign's performance notes assume ten thousand rows and reason about
`removeFirst` memmove costs at that size. Both `MockServerRuntime.maxRequestLogEntries` and the
engine's `AsyncStream` `.bufferingNewest(1000)` cap at **1,000**, independently. The drawer's own
comment depends on it — it watches `requestLogs.last?.id` rather than `.count` precisely because from
request 1,001 the count is permanently 1,000.

So any target stated at 10k is measuring a configuration this app cannot reach.

## Baseline — `RequestLogFilter`, 2026-08-08

Machine: Mac mini, macOS 26, Swift 6.2. `swift test --filter RequestLogPerformanceTests`.

| Measurement | Baseline |
|---|---|
| Filter a full 1,000-entry buffer, one pass, three predicates active | **~2ms** |
| 20 passes over 1,000 entries, unmatched + text | **~12ms** |
| 200 passes with an inert filter (the default state) | **~47ms** |
| 20 passes with a query that matches nothing (all three fields compared) | **~41ms** |
| Superlinearity check: 4× entries → cost ratio | **< 12×** (linear would be ~4×) |

The one that matters day to day is the first: filtering runs on **every keystroke** in the filter
field, so exceeding one frame (16ms at 60Hz) is felt directly as the field lagging behind typing. At
~2ms there is an order of magnitude of headroom, and that is the number to re-check when #33 adds the
journey-only toggle and the endpoint scope.

## Still to capture (needs the Xcode runner)

These are #24's, and none of them can be taken while the test services are down:

1. `WorkspaceView.body` evaluations per served request — today ≥1, target 0
2. `appendLog` p50/p99 at buffer-full
3. Allocations per served request inside `tableBody` — three whole-log allocations today
4. Sustained req/s with the window open vs minimised. **If these differ, the log pipeline is
   back-pressuring the server**, which is the finding that would change #24's design rather than
   just its numbers
5. `logStream` drop count under load — `.bufferingNewest(1000)` drops silently and nothing counts it
6. Idle CPU with the server running and zero traffic

## How to re-run

```bash
swift test --filter RequestLogPerformanceTests
```

Thresholds are deliberately loose. A benchmark that fails on a busy laptop teaches people to ignore
it; these catch an accidental O(n²), not a few milliseconds.

## What #24 changed, and what it did not

The six measurements above still want Instruments. But three of the four whole-log scans in
`WorkspaceView.body` did not need a profiler to justify removing, because they were **provably
redundant** rather than merely slow — and `body` re-evaluates on *every served request*, since
appending to `requestLogs` invalidates it.

| Scan | Was | Now |
|---|---|---|
| Toolbar unmatched badge | `count { isMissingConfiguration }` — O(n) | `MockServerRuntime.unmatchedCount` — O(1) |
| Overview unmatched count | the same scan, a second time | the same O(1) read |
| Endpoint traffic | `.enumerated().filter().sorted().map()` — O(n log n) **plus two array allocations** | `count(where:)` — O(n), no allocation |
| Selected-request lookup | `first(where:)` — O(n) | unchanged; see below |

The third row is the one worth naming, because it is not a performance bug so much as a leftover.
`EndpointTrafficQuery.logs(forEndpoint:in:)` built a fully sorted array of matching entries, and its
only caller read `.isEmpty` and `.count` from it. The panel that rendered those rows was retired in
#26; the sort outlived it by four issues. At the 1000-entry cap that is an O(n log n) sort per served
request to produce a single integer.

Two sibling helpers went with it. `summary(for:)` and `statusBreakdown(for:)` had **no production
caller at all** after #26 — only tests, which kept passing and so kept them looking alive. That is
the failure mode worth remembering here: a green test is not evidence that the code beneath it is
reachable. `Tests/WorkspaceFeatureTests/EndpointTrafficTests.swift` lost three quarters of its length
and covers strictly more of what ships.

**The unmatched tally is maintained incrementally**, which needs care at exactly three points: an
append, an eviction at the cap, and a wholesale replacement (the Clear button, or a restore). The
first two are tracked arithmetically; the third cannot be, so `didSet` recounts — which is correct
because it happens when a human presses a button, not when a request arrives. All three are covered
in `MockServerRuntimeTests`, and each test asserts the tally equals the full scan it replaced.

**The selected-request lookup was left alone deliberately.** It is O(n), but it only runs while a row
is selected, it allocates nothing, and a UUID comparison across 1000 elements is not what a profiler
would flag first. Replacing it with an index would add a second structure to keep in step with the
eviction path — the exact bookkeeping that makes the tally above worth testing three ways — for a
saving nobody has measured. It stays until item 1 of the list above says otherwise.
