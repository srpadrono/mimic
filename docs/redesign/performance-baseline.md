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
