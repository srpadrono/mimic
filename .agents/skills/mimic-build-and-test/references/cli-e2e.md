# `run_cli_e2e.sh`: what it needs, and why no gate runs it

It covers a seam nothing else does — process launch, discovery file, real sockets — and `ci.sh`
still does not run it. That is deliberate and the reason is written into both `ci.sh` and
`.github/workflows/ci.yml`: **it cannot find the CLI those gates just built.** No `xcodebuild` step
in either passes `-derivedDataPath`, so the products land in DerivedData outside the checkout while
the script looks for `*Build/Products*` *inside* it, then falls back to whatever `mimic` is on
`PATH` — an installed build, not this one. `AppLauncher.resolveExecutable` picks the *app* the same
way, independently (`MIMIC_APP_PATH`, `/Applications/Mimic.app`, `~/Applications/Mimic.app`), so
wiring it up means exporting two paths, both pointing at what the run just built. A green e2e against
an installed build says nothing about the working tree.

What it is no longer is dangerous, and that is a recent change worth knowing because the old
behaviour is what kept it out of the docs' recommended path:

- **It stops the instance it launched, by pid.** The cleanup trap used to call `mimic app stop`,
  which reads the *shared* `control.json` and signals whatever pid it names — so on a machine with
  Mimic open, running this script quit the developer's own instance, on every exit path including
  the ones where it had launched nothing. The pid now comes out of what `mimic app start` printed
  about the process it launched.
- **It needs `MIMIC_CONTROL_FILE`, and it exports it** (`"$WORK/control.json"`). Both halves of the
  contract resolve that variable through one function — `ControlEndpointDiscovery.overrideURL` in
  `Domain` — and the override *replaces* the search list instead of joining the front of it, so this
  run cannot fall through to a developer's real instance in either direction: the app's write side
  (`ControlEndpointFile` in `ControlPlane`) advertises inside `$WORK`, and the CLI's reader searches
  only there. The script still asserts the file exists after launch, because the write half is the
  app's to honour, and if the file is missing the instance advertised itself at the shared path
  after all.
- `set -euo pipefail` is now on, so a line added without a trailing `|| fail` cannot pass silently.

**The CLI reads the file through the same contract the app writes through.** `MimicCLICore` used to
carry a second copy of the discovery reader — it links no `ControlPlane` — and that copy searched
only the two Application Support paths, so `MIMIC_CONTROL_FILE` was honoured on the write side alone:
move the file and `mimic` found no `control.json` at all, sent no `X-Mimic-Token`, and every command
came back 401 while `mimic app start` still looked fine, because `isReachable` accepts a 401 as
proof something answered. An isolated run therefore had to export the destination
(`MIMIC_CONTROL_URL` or `MIMIC_CONTROL_PORT`) *and* the credential (`MIMIC_CONTROL_TOKEN`) by hand —
four variables. The read half now lives once, in `Domain` as `ControlEndpointDiscovery`, and the CLI
resolves through it, so destination and credential both come out of the relocated file and the
four-variable dance is gone. The script still exports two of them for reasons that are not CLI
plumbing: `MIMIC_CONTROL_PORT` is the *app's* bind port (`ControlPlaneCoordinator.resolvePort` reads
it), kept off the default 8787 a developer's own instance is holding, and `MIMIC_CONTROL_TOKEN` —
which `ControlServer.init` takes for the token it demands and
`ControlEndpointDiscovery.resolveToken` reads first on the sending side — is fresh per run so a
leftover file from a previous run cannot authenticate against this one.

## Linux is not macOS

When touching anything the Linux build compiles, remember it is not macOS: `URLSession` lives in
`FoundationNetworking`, the BSD socket calls live in `Glibc` rather than `Darwin`, and some C types
are wider there. `Tests/MockServerEngineTests/PlatformSockets.swift` keeps those differences in one
place — verify with `docker run --rm -v "$PWD":/src -w /src swift:6.2 …` rather than guessing.
