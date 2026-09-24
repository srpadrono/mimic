# Journeys

A journey scripts how responses change across requests. The active journey gets the first chance to answer; calls it does not script normally fall through to endpoints. A project can store many journeys but run one at a time.

```text
1. POST /login           → 200
2. GET  /account-summary → 500
3. GET  /inbox           → 200
4. GET  /account-summary → 200
```

The second account-summary call succeeds because the cursor has advanced. Try the built-in flow with `mimic journey add-template retry-after-failure --activate`, then inspect `mimic journey status` and the request log.

## Matching

| Mode | Behavior |
| --- | --- |
| `orderedPerEndpoint` (default) | A request may consume the earliest matching unexhausted step at or after the cursor, even if another route's earlier step remains pending. |
| `strictSequence` | Only the current step may match; another request follows `unmatchedBehavior` and leaves the cursor unchanged. |

Path segments use endpoint matching rules, including `:param` wildcards. Query strings are not match criteria. GraphQL steps can also name an operation. Set `unmatchedBehavior` to `notFound` when an unscripted call should fail with `404` instead of falling through.

## Step outcomes and progression

A response step specifies status, headers, body, content type, optional delay, and `repeatCount`. Step delay adds to the project's global delay. A transport-failure step instead drops the connection or holds it for `holdMs` before dropping it. An HTTP `500` is still a response, so use a transport failure when testing offline or timeout handling. Clients may retry failed idempotent requests; increase `repeatCount` if the failure must survive those retries.
Imported projects reject negative delays and timeout holds, and require a repeat count of at least one. The total wait for one response is limited to 300,000 ms (5 minutes): global plus endpoint delay, or global plus journey step delay plus timeout hold. An imported project above the limit is rejected. Older projects already stored on this Mac still open and can be edited; their waits are capped to 5 minutes while serving. Unchanged older values and reductions can be saved so a project can be repaired one field at a time, but a new or increased wait above the limit is refused. An export of an older project with excessive waits must be repaired before it can be reimported.

Automatic progression retires a step after its repeat count. With `autoAdvance: false`, it keeps answering until `mimic journey advance` is called. Completion can stop or restart the journey. `mimic journey restart` rewinds it, and activation always starts a fresh run. The serving actor reads, resolves, and advances the cursor atomically so concurrent requests do not consume the same step.

```bash
mimic journey activate "Session expiry"
mimic reset --scope all              # rewind and clear traffic before a test
# Drive the client under test.
mimic journey status | jq -e '.journeyStatus.isComplete'
```

The window can create steps from logged requests, or save a selected run of requests as a journey in arrival order. Repeated identical polls become one step with a repeat count. Use `mimic journey export` and `import` to share a flow; `step add-batch` appends steps from an export.

## Groups and templates

Journeys can be grouped in the navigator. `mimic journey create "Payment retry" --group Checkout` sets a group; `journey update ... --group ""` clears it. Group membership is saved and exported. `mimic journey templates` lists the built-in examples, including retries, session expiry, maintenance, and offline recovery. See [CLI](CLI.md#journeys) for commands.
