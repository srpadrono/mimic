# Current limits

This page describes behavior that callers need to plan around. It is not a release schedule; see [CHANGELOG.md](../CHANGELOG.md) for shipped versions.

- **Spec import requires the window.** HAR and OpenAPI/Swagger parsing plus review have no control command. `mimic project import` loads a Mimic project export instead. A script can parse a spec itself and create endpoints and scenarios through the CLI.
- **Update installation requires the window.** `mimic app update-check` reports availability; macOS Installer asks a person to approve installation.
- **Matching uses method, path, and GraphQL operation.** Headers, query parameters, and request bodies are not match criteria. GraphQL batch and persisted-query limits are in [GraphQL](GRAPHQL.md#known-limits).
- **Responses are static.** There is no request-value templating or general counter; journey repeat counts provide fixed sequences.
- **One journey runs per project.** Its live cursor belongs to the server run, not to each client.
- **Port changes require a restart.** `mimic server status` distinguishes configured backends from active listeners when a restart is pending. Upstream URL and pass-through changes apply live.

Ideas under consideration include header and body matching, response templating, and journey assertions. None has a promised release date.
