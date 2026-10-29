# QA prompt: test the Checkout feature with Mimic

Paste this into a coding agent (Claude Code, or any agent that can run shell commands) started in
`docs/examples/acme-store`. Mimic must be running with the `Acme Store` project open and one real
checkout already recorded (see the [README](../README.md)).

---

You are the QA engineer for **Acme Store**, a Mac app in this folder. Your job is to prove the
**Checkout** feature handles everything its backends can do, not only the happy path, and to fix
the app when it does not.

The app talks to three backends. Mimic stands in for all three, one local port each: Auth on 8080,
Catalog on 8081, Payments on 8082. One real checkout has already gone through Mimic, so it holds
the real responses for every call on the happy path.

Do not read `qa/reference/`. It holds an answer key.

## 1. Read

- What the server actually said: `mimic log list --limit 50` (JSON) and `mimic endpoint list`.
- What the server can say: `openapi.yaml`, including every documented error and the client rules
  at the top.
- What the app does about it: `Sources/AcmeStore/Store.swift` and `API.swift`.

## 2. Plan

Write a table of every Checkout scenario worth testing: one row per distinct backend behaviour
the spec allows on the path from sign-in to receipt. For each row give the journey steps you will
script (method, path, backend, status or failure, body, headers, repeat count, delay) and what the
app must show, taken from the spec's rules, not from the code. Keep the happy path as row 1. Show
the table before you go on.

## 3. Script

Create one Mimic journey per row with the CLI, in the group `Checkout QA`:

```bash
mimic server status                      # backend UUIDs: Catalog and Payments; Auth is "primary"
mimic journey create "Checkout: <scenario>" --group "Checkout QA" --summary "<what it proves>"
mimic journey step add "Checkout: <scenario>" POST /orders --backend <UUID> --status 503 \
  -H 'Retry-After: 1' --repeat-count 2 --body '{"error":"payments_unavailable"}'
mimic journey step add "Checkout: <scenario>" GET /products --backend <UUID> --fail timeout --hold-ms 6000
```

A journey only scripts what changes; every other call falls through to the recorded responses.
Turn forwarding off first so nothing reaches a real server: `mimic server configure --pass-through
false`, and `mimic server backend update <UUID> --pass-through false` for each backend.

## 4. Run

Run each scenario with `mimic/run.sh "<journey name>"` (`--none` for the happy path). It plays the
app through a checkout and prints the app's result, the journey's progress and Mimic's request log.
Run them one at a time, in table order.

A scenario passes only when all three agree with the expectation: the app's outcome and banners,
every journey step served, and the request log showing the calls the spec requires (for example,
the right number of `POST /orders`).

## 5. Fix and re-run

For each failure, find the cause in the app's code, fix it in the smallest change that makes the
app follow the spec, and run **every** scenario again, not only the one that failed. Repeat until
all pass.

## 6. Report

Finish with the scenario table updated with a result per row, each failure you found with the log
lines that proved it, and the diff of each fix.
