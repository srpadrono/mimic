# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] — 2026-08-04

First beta.

Mimic runs local mock API servers on macOS, so client work can start before the backend is ready.
Define endpoints, configure responses, switch scenarios, script journeys, simulate latency and
network failures, and watch live request traffic. The server runs in-process.

Everything the window does is also scriptable. The `mimic` CLI and a loopback HTTP control API expose
the same operations, so a UI test or an agent can create a configuration, script a flow and drive a
run without touching the interface.

### Included

- **Endpoints and scenarios** — path matching with `:param` segments, global and per-endpoint latency,
  and scenarios that switch a whole set of responses at once.
- **Journeys** — ordered response sequences, so the same route can fail and then succeed. Per-step
  status, headers, body, delay and repeat count; transport failures; automatic or held progression;
  many stored, one active. A logged request can be captured straight into a step, so a flow can be
  built by running it once.
- **GraphQL** — requests matched by operation name rather than by path, falling back from the client's
  `operationName` to the name in the document to the first root field.
- **Import** — HAR captures and OpenAPI/Swagger documents become endpoint candidates you review before
  they land. Credentials are redacted on the way in, best-effort.
- **Request log** — live traffic with full request and response detail, formatted and syntax-coloured
  bodies, copy as `curl`, and unmatched requests called out so you can see the mocks you are missing.
- **CLI and control API** — the whole command surface over HTTP, bound to `127.0.0.1` only, with a
  per-instance token, JSON output and meaningful exit codes. Headless mode for CI and agents.

Ships as a signed and notarised installer that puts Mimic.app in `/Applications` and `mimic` in
`/usr/local/bin`.

Beta, and versioned below 1.0 deliberately: the interface and the stored project format may still
change between releases.

[0.9.0]: https://github.com/srpadrono/mimic/releases/tag/v0.9.0
