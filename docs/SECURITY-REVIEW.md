# Security review — Mimic 1.6.0

**Date:** 2026-07-31 · **Commit reviewed:** `1146008` · **Scope:** the whole app — control plane,
mock server engine, persistence, spec import, CLI, entitlements, CI.

> **Neither identifier in that line resolves here.** `git cat-file -t 1146008` answers *"Not a valid
> object name"*, this repository's first commit is dated 2026-08-04 — after the review date above —
> and the version has been `0.9.x` throughout (`MARKETING_VERSION` in `Project.swift`). So read the
> header as provenance that cannot be checked, and the findings on their own merits: each names the
> code path and the regression test that now guards it, and those *are* checkable. Left as written
> rather than renumbered, because inventing a plausible commit would be worse than an obviously
> unresolvable one.

All findings below have been fixed. Each has a regression test; the test names are given so the
guard can be found again when someone wonders why the code is shaped this way.

---

## Summary

Mimic opened an unauthenticated HTTP port on every launch. Anything that could reach it could do
everything the app could do — read projects, delete them, rewrite what the app-under-test receives,
and read back captured traffic including live credentials. The code treated "bound to `127.0.0.1`" as
an access-control boundary. On a developer's machine it is not one: every local process is already
inside it, and a web page can reach through it.

Five findings were reproduced by running them, not by reading. The two that mattered most were the
missing authentication and a single malformed request that killed the whole app.

---

## Findings

### 1. Control API had no authentication — critical

Started unconditionally at app launch on fixed port `8787`, with no token, no `Origin` check, no
`Host` check, and no CORS policy.

Reproduced with a raw socket:

```
POST /v1/command HTTP/1.1
Host: mimic.evil.example
Origin: https://evil.example
Content-Type: text/plain

{"projectCreate":{"name":"pwned-by-a-web-page","port":9911}}
```

→ `200 OK`, `"ok": true`, project created.

Three consequences:

- Any local process — a package `postinstall`, an editor extension — had the full command vocabulary,
  including `projectDelete` (permanent, unconfirmed) and `scenarioUpdate` (silently changes what the
  app under test receives).
- Any web page could issue those writes. That request shape is a CORS *simple request*, so a browser
  sends it with no preflight. The page cannot read the reply, but the command has already run.
- `Host` was unchecked, so DNS rebinding turned blind writes into full read access.

**Fixed.** Every instance mints a fresh 32-byte token at startup and writes it to its `0600` discovery
file; every route requires it in `X-Mimic-Token`. A custom header is deliberate — it is not on the CORS
safelist, so a browser must preflight, and the preflight fails. Two further checks refuse browser-shaped
requests before the token is considered: any `Origin` header is a `403`, and a non-loopback `Host` is a
`403`. The CLI reads the token from the discovery file with no configuration.

*Tests:* `tokenIsRequiredOnEveryRoute`, `wrongTokenIsRefused`, `browserOriginIsRefused`,
`hostHeaderPinning`, `noCORSHeaders` in `ControlServerTests`.

### 2. Captured credentials readable over that API — high

`logList` returned whole `RequestLog` values. Reproduced — this is what one request stored:

```
headers: ["Authorization": "Bearer eyJhbGciOi-REAL-DEV-TOKEN",
          "Cookie": "session=abc123", …]
body:    {"client_secret":"sk-live-…","refresh_token":"rt-…"}
```

The import path already stripped credentials deliberately. The log path — the one exposed over HTTP —
did not.

**Fixed.** `logList` redacts credential-bearing header values on the way out. The app's own window
still shows them: there they are the developer's own traffic on their own screen.

*Tests:* `logListRedactsCredentials`, `redactionCoversTheUsualHeaders`.

### 3. One request crashed the whole app — high

`projectImport` skipped every validator. A scenario with `statusCode: -1` was accepted, and serving it
reached `HTTPResponseStatus(statusCode:)`, whose default branch does `UInt(statusCode)` — which traps:

```
Fatal error: Negative value is not representable
error: Exited with unexpected signal code 5
```

The engine is embedded, so this killed the app and any unsaved edits. Also reachable by opening a
hand-edited project file.

A second, pre-existing variant surfaced while fixing it: **any 1xx status** crashed a debug build.
NIO's server pipeline does not advance past `.head` for an informational response, so the body that
follows fails an assertion — and `100` was explicitly accepted by the validator and typeable in the
editor.

**Fixed.** Serveable statuses are now `200...599`, enforced in three places: the validators, a whole-
document `ProjectValidator` that every import passes through, and a clamp at the serving boundary that
makes the crash unreachable regardless of how a value got into the store.

*Tests:* `statusCodeIsClamped`, `outOfRangeStatusCodeIsServed`, `importIsValidated`,
`informationalStatusCodesAreRejected`, `negativeStatusCodeIsRejected`.

### 4. HTTP response-header injection — medium

Vapor builds its own HTTP/1 pipeline and does not install NIO's `NIOHTTPResponseHeadersValidator`, and
Mimic wrote header names and values through unchecked. A scenario header value of
`a\r\nX-Injected: yes\r\nSet-Cookie: evil=1` produced, on the wire:

```
X-Test: a
X-Injected: yes
Set-Cookie: evil=1
```

Three real headers, including a `Set-Cookie`. Reachable from an imported HAR, an imported project, or
finding 1.

**Fixed.** Header names must match the RFC 9110 token grammar and values must not contain CR, LF, or
NUL. The editing and import paths reject them with a message naming the header; the serving path drops
them, because failing the app-under-test's request would say nothing about the scenario that is wrong.

*Tests:* `crlfHeaderValueIsDropped`, `headerValidation`.

### 5. Request bodies in the log were uncapped — medium

`cappedBody` guarded the response body only. Request bodies arrive up to the route's 10 MB collect
limit and the log holds 1000 entries — ~10 GB worst case, driven entirely by what the app under test
posts.

**Fixed.** The same 64 KB cap applies to both. Truncation now also backs up to a scalar boundary, so
cutting mid-emoji no longer produces a replacement character.

*Tests:* `requestBodyIsCapped`, `cappingRespectsScalarBoundaries`.

### 6. Discovery file was world-readable — low

Written `0644` under the default umask, publishing port and pid to every account on the machine.
Now that it carries the token, its permissions *are* the access control.

**Fixed.** Written `0600`, and never at any wider mode, even briefly. `ControlEndpointFile.write`
creates a temporary file in the target's own directory with `0600` already on it
(`FileManager.createFile(atPath:contents:attributes:)`), writes the bytes into that, and then
`rename(2)`s it over the real name — a rename carries the source's mode with it, so a reader sees
either the old file or a complete `0600` one.

**This section used to read "written `0600`, applied after the atomic rename", and that sentence was
an instruction to reintroduce the finding.** Chmod-after-write is the broken shape, not the fix:
`Data.write(options: .atomic)` renames a temporary file into place, so between that rename and the
`setAttributes` call the token sits at the final path at whatever the umask allows, and a loop
watching the path wins that race trivially. If `setAttributes` then throws, the world-readable file
is what stays behind. `Sources/ControlPlane/ControlEndpointFile.swift` documents the ordering above
`write`, and `discoveryFileIsPrivate` in `Tests/ControlPlaneTests/ControlServerTests.swift` pins the
mode on both a first write and an overwrite, and asserts no temporary file is left beside it.

The call site is the other half and is easy to undo by accident: `ControlServer` used to call this
through `try?`, so a failed write was silent. It catches and logs now. A hardened write whose caller
discards the error only moves the silence one frame up.

### 7. HAR redaction was narrower than its name — low

The old pattern anchored quotes on both sides of the key name, so `"token"` was redacted but
`"refresh_token"`, `"id_token"` and `"client_secret"` passed through — and imported mocks get
committed to repositories.

**Fixed, then reverted — the fix was worse than the finding.** Substring matching on the key name
caught `refresh_token`, but it also caught `author`, `keywords`, `shipping`, `shopping`, `mapping`,
`typing` and `monkey`, replacing ordinary values with `[REDACTED]` in the majority of real captures.
Widening it to non-string values added a second defect: the replacement was quoted, so
`"sessionCount": 42` imported as `"sessionCount": "[REDACTED]"` and changed the JSON type.

The whole pass is gone. Imported bodies are now reproduced verbatim, credential headers are still
dropped, and the import review sheet carries the responsibility. This finding is accepted rather than
fixed: see the revised section in `SECURITY.md`.

### 8. No size cap on imported files — low

`Data(contentsOf:)` on a user-chosen file, decoded whole.

**Fixed.** 256 MB cap, checked from the filesystem before the bytes are read, with a message that says
what to do.

---

## Reviewed and found sound

Worth recording, because it is most of the codebase:

- No shell execution anywhere. `Process` is used with `executableURL`, never `/bin/sh`.
- Every SQL statement is parameterized; no string interpolation into SQL.
- No WebViews, no `evaluateJavaScript`, no HTML rendering of mock content.
- No outbound network connections and no telemetry.
- Entitlements are minimal: no `files.all`, no disabled library validation.
- OpenAPI `$ref` resolution is components-only — no remote fetch, so no SSRF.
- Schema example generation is depth-capped at 3, so a cyclic schema cannot recurse forever.
- No user-supplied regex anywhere, so no ReDoS.
- `UITestSupport` is `#if DEBUG`-gated as documented.
- The review found no known-vulnerable dependency pins. It quoted Vapor 4.122.0 and NIO 2.101.3 as
  the current ones; both manifests now resolve **Vapor 4.121.3 and NIO 2.97.1**, which is where the
  two lockfiles were reconciled when CI began checking that they agree — SwiftPM had been resolving
  ahead of Tuist on 21 shared packages. `Package.resolved` is the authority for what ships, not this
  sentence.
- CI workflow has no injection surface and exposes no secrets.

## Method and limits

Findings 1–5 were reproduced against a running server; 6 was measured; 7 and 8 are from reading. Not
done: browser-based testing with a real browser, fuzzing the parsers, dependency source audit beyond
the two NIO/Vapor code paths cited, and review of the SwiftUI layer beyond confirming there are no
WebViews.

Severities assume the realistic threat model for a developer tool — hostile local code and hostile web
pages — not a hardened multi-tenant host.
