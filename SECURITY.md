# Security

## Reporting a vulnerability

Open a [private security advisory](https://github.com/srpadrono/mimic/security/advisories/new), or
email the maintainer. Please do not open a public issue for something exploitable.

Include what you did, what happened, and what you expected. A failing `curl` or a small project file
is worth more than a description.

## What Mimic is, in security terms

Mimic is a developer tool that runs two HTTP servers on your machine:

| Server | Default port | Bound to | Who may talk to it |
|---|---|---|---|
| **Mock server** | 8080 | `127.0.0.1` | Anything local. It is *meant* to be reachable — that is the product. |
| **Control API** | 8787 | `127.0.0.1` | Only a caller holding this instance's token. |

Both bind loopback only and never a routable interface. The control API starts automatically with the
app so that `mimic` works without setup.

### Loopback is not an authentication boundary

This is the assumption worth stating plainly, because an earlier version of Mimic relied on it. On a
developer's machine, "bound to `127.0.0.1`" keeps out the network and nothing else:

- Every process you run is already inside it — including a build script, a package `postinstall`, or
  an editor extension.
- A web page you visit can send requests to a loopback port. It cannot normally *read* the response,
  but a request that deletes a project does not need to be read.
- DNS rebinding can make an attacker's page same-origin with a loopback port, which lifts that
  read restriction too.

So the control API does not rely on it. It requires a token, and it refuses browser-shaped requests.

### The control API's token

Every instance mints a fresh token at startup — 32 bytes from the system CSPRNG — and writes it to
its discovery file:

```
~/Library/Application Support/devxa.Mimic/control.json          # daemon
~/Library/Containers/devxa.Mimic/Data/…/control.json            # sandboxed app
```

That file is written `0600`. It is readable by your user account and nothing else, which is what makes
it usable as a credential: the `mimic` CLI can read it with no configuration, and a web page cannot
read it at all.

Every route requires the token in an `X-Mimic-Token` header, `/v1/health` included. A request without
it gets `401` and does nothing.

Two further checks refuse browser-shaped requests before the token is even considered:

- **Any `Origin` header** → `403`. Legitimate callers here are CLIs and scripts; only a browser sends
  one, and there is no origin this API wants to talk to.
- **A non-loopback `Host`** → `403`. This is what breaks DNS rebinding, which works by pointing an
  attacker-controlled *name* at `127.0.0.1`.

No `Access-Control-Allow-*` header is ever sent, so a browser cannot read a response even if one were
somehow produced.

To drive the API without the CLI, read the token from `control.json`:

```bash
TOKEN=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' \
  < ~/Library/Application\ Support/devxa.Mimic/control.json)
curl -s -H "X-Mimic-Token: $TOKEN" http://127.0.0.1:8787/v1/state
```

Or set `MIMIC_CONTROL_TOKEN` on both the instance and the caller, which is the usual arrangement in CI
and in containers.

### The mock server has no authentication, by design

The mock server answers *as* the API under test. Adding credentials to it would mean the app under
test needs credentials it would not need against the real backend, which defeats the point. It is
loopback-only and serves only what you configured.

Consequently: **do not put real secrets in mock responses.** Anything local can read them.

## What Mimic stores, and where

- **Projects** — SQLite at `~/Library/Application Support/devxa.Mimic/mimic.sqlite` (inside the
  sandbox container for the app). No encryption; it has your machine's file permissions.
- **The request log** — in memory only, capped at 1000 entries, never written to disk. It is cleared
  when the app quits.

### Captured traffic contains real credentials

The request log records what the app under test sent, and that routinely includes a bearer token or a
session cookie for a staging API. Two consequences:

- `logList` over the control API **redacts** credential-bearing header values (`Authorization`,
  `Cookie`, `Set-Cookie`, `X-API-Key`, and similar). The app's own window shows them unredacted,
  because there they are your traffic on your screen.
- **Screenshots and exported projects are not redacted.** Check before sharing.

### Imported captures carry whatever was captured

Importing a HAR or an OpenAPI spec drops credential *headers* — `Authorization`, `Proxy-Authorization`,
`Cookie` and `Set-Cookie` are not copied onto the mock, because a header is framing and dropping one
does not change the payload the client reads.

**Response bodies are imported verbatim.** A capture of an OAuth exchange therefore lands with the
real token in it.

There used to be a redaction pass over imported bodies, and it was removed because it broke more than
it protected. The key match was a substring, so `author`, `keywords`, `shipping`, `shopping`,
`mapping`, `typing` and `monkey` all had their values replaced with `[REDACTED]` — ordinary fields in
ordinary responses. A numeric match came back quoted, turning `"sessionCount": 42` into
`"sessionCount": "[REDACTED]"` and changing the JSON type under a client entitled to a number. An
importer that edits the payload produces a mock answering something the real server never said, which
defeats the purpose of importing a capture at all.

**Review an imported mock before committing it.** The import sheet shows every candidate before it
lands, and that review is now the only thing standing between a captured credential and your
repository.

## Hardening in the serving path

A project can arrive as data — an import, a shared fixture, a file edited outside the app — so the
serving path does not trust what it is given:

- **Status codes** are clamped to `200...599`. Outside that range they used to crash the process: a
  negative code traps converting to `UInt`, and a 1xx trips an assertion in NIO's server pipeline.
- **Response headers** containing CR, LF, or NUL, or with a name outside the RFC 9110 token grammar,
  are dropped. A CR in a header value does not stay inside that header — it ends it, and what follows
  is parsed by the client as further headers.
- **Request and response bodies** in the log are capped at 64 KB each.
- **Imported projects** are validated whole before being stored, to the same rules the editor enforces.

## Sandbox and entitlements

The app runs under App Sandbox and Hardened Runtime with three entitlements beyond the sandbox
itself:

| Entitlement | Why |
|---|---|
| `network.server` | The mock server and the control API. |
| `network.client` | Vapor's runtime opens loopback connections. |
| `files.user-selected.read-write` | Import and export, through the file picker only. |

There is no `files.all`, no disabled library validation, and no `allow-unsigned-executable-memory`.
Mimic makes no outbound network connections and sends no telemetry.

## Supported versions

Fixes land on the latest release. There are no maintained release branches.
