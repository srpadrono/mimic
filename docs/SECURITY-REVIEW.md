# Security review — Mimic 1.6.0

**Date:** 2026-07-31 · **Commit reviewed:** `1146008` · **Scope:** the whole app — control plane,
mock server engine, persistence, spec import, CLI, entitlements, CI.

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

**Fixed.** Written `0600`, applied after the atomic rename.

### 7. HAR redaction was narrower than its name — low

The old pattern anchored quotes on both sides of the key name, so `"token"` was redacted but
`"refresh_token"`, `"id_token"` and `"client_secret"` passed through — and imported mocks get
committed to repositories.

**Fixed.** Substring matching on the key name, non-string values (`"token": 123456`), and bare JWTs
are all covered now. It remains best-effort, and `SECURITY.md` says so rather than implying a
guarantee.

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
- Dependencies current (Vapor 4.122.0, NIO 2.101.3); no known-vulnerable pins.
- CI workflow has no injection surface and exposes no secrets.

## Method and limits

Findings 1–5 were reproduced against a running server; 6 was measured; 7 and 8 are from reading. Not
done: browser-based testing with a real browser, fuzzing the parsers, dependency source audit beyond
the two NIO/Vapor code paths cited, and review of the SwiftUI layer beyond confirming there are no
WebViews.

Severities assume the realistic threat model for a developer tool — hostile local code and hostile web
pages — not a hardened multi-tenant host.
