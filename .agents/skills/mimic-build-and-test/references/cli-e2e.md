# `run_cli_e2e.sh`: what it needs, and what runs it

It covers a seam nothing else reaches — a real process launch, the discovery file on disk, a real
control socket, and `mimic` as a binary rather than `MimicCommand.run(arguments:)` called in
process — and both `ci.sh` and the macOS job now run it. `ci.sh` runs it last; the macOS job runs it
after the UI suite and before `Build (Release)`, so the Debug products it drives are the only ones
in that directory.

What kept it out was never safety, it was that **it could not find the CLI those gates had just
built.** No `xcodebuild` step in either passed `-derivedDataPath`, so the products landed in
DerivedData outside the checkout while the script looks for `*Build/Products*` *inside* it, and it
fell through to whatever `mimic` was on `PATH` — an installed build, about which a green run says
nothing. `AppLauncher.resolveExecutable` picks the *app* the same way and independently
(`MIMIC_APP_PATH`, `/Applications/Mimic.app`, `~/Applications/Mimic.app`), so wiring it up meant
naming two paths, not one. Both callers now hold one `DERIVED_DATA` — `.artifacts/DerivedData`,
inside the checkout — and pass it to **every** `xcodebuild` step, because those builds are shared and
pointing one of them somewhere new makes the rest re-resolve and rebuild into the old location. Each
then exports `MIMIC_BIN` and `MIMIC_APP_PATH` at `$DERIVED_DATA/Build/Products/Debug`, and checks
both exist before the script starts, so "the products are not where this caller thinks" cannot arrive
later disguised as a failed assertion. `MIMIC_BIN` from the environment now wins over the script's
own `find`.

**`ci.sh` gates on it; the macOS step does not yet.** The first round on a runner passed end to end
in four seconds, the flag came off on that evidence, and the very next round failed — with every
other step green. It fails at the discovery-file assertion, and the reason it is not fit to gate is
what that failure looks like from outside: `ControlServer.start` binds the socket *before* it writes
the file, so `mimic app start` reports the instance reachable while nothing has been advertised yet,
and a failed advertisement is deliberately non-fatal — the error goes to the application's own
logger, and `AppLauncher.launch` gives the child process `FileHandle.nullDevice` for stdout **and**
stderr on every launch, headless or not, so that logger writes into nothing. (The redirection is not
a headless behaviour and never was: a launcher that inherited stdout would interleave the app's
logging into the JSON an agent is parsing, which is true with a window open too.) The condition is
unobservable by construction, so the script now reports which of the two causes it was (advertised
at the shared path, or advertised nowhere) and the step stays non-gating until the cause is fixed.
`ci.sh` gates from the start, because a laptop failure is one you can read on the spot.

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
