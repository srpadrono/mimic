# Security

Report vulnerabilities through a [private GitHub security advisory](https://github.com/srpadrono/mimic/security/advisories/new). Include a minimal reproduction. Do not publish an exploitable report as an issue.

## Local servers and credentials

Mimic binds its mock server (default port `8080`) and control API (default port `8787`) to `127.0.0.1`. The mock server is intentionally unauthenticated: local clients must be able to call it as the API under test. Do not put real secrets in mock responses.

The control API requires a fresh per-instance token in `X-Mimic-Token` on every route, including health. It rejects requests with an `Origin` header or a non-loopback `Host`. Loopback alone is insufficient protection because local processes and web pages can send requests to it.

The instance writes its token to `control.json` with mode `0600` under the app's Application Support directory (inside the container for the sandboxed app). The `mimic` CLI discovers the instance and token there. It attaches a discovered token only to `http://127.0.0.1` on the advertised port, matching the address the server binds. Explicit destinations using `localhost`, IPv6 loopback, remote hosts, or forwarded ports need a caller-supplied `MIMIC_CONTROL_TOKEN`. See [CLI discovery](docs/CLI.md#finding-an-instance).

## Stored and captured data

Projects are stored in SQLite in Application Support with normal user file permissions, without encryption. Visible request-log entries are held in memory and cleared when the app exits. Complete pass-through bodies larger than the log preview can use private temporary files while their log entries are retained. Traffic may contain authorization headers, cookies, or response body secrets.

The control API redacts credential-bearing *header values* in log output; the app window shows the original traffic. Screenshots, project exports, and response bodies are not automatically redacted. Review them before sharing.

HAR and OpenAPI import omit sensitive credential headers but preserve text response bodies. A captured token inside JSON therefore remains in the imported mock. The import review is where to remove it before saving or committing the project. Pass-through capture likewise requires reviewing saved response bodies; binary, compressed, truncated, or unsuitable partial responses cannot become text mocks.

## Serving limits

The server validates imported project data before use, clamps invalid status codes, drops unsafe response headers, and caps traffic previews. The app uses App Sandbox and Hardened Runtime; import and export access comes through the file picker. Fixes target the latest release; older release branches are not maintained.
