# Contributing

Contributions are welcome. This file covers building from source and the gates a change has to pass.
Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first — it explains the domain language and the
module boundaries, which is what makes the code predictable.

## Build from source

**Requirements:** macOS 26+, Xcode with the Swift 6.2 toolchain, and [Tuist](https://tuist.io).

```bash
tuist install && tuist generate --no-open
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Debug build
```

Re-run `tuist install && tuist generate` after any change to `Project.swift` or `Tuist/Package.swift`.

Most of the codebase doesn't need Xcode at all:

```bash
swift build      # Domain, Persistence, MockServerEngine, SpecImport, ControlPlane, CLI
swift test
```

## Two manifests, one source tree

[`Package.swift`](Package.swift) and [`Project.swift`](Project.swift) point at the **same**
directories. SwiftPM builds the portable modules; Tuist builds the app, which needs SwiftUI, an app
bundle, entitlements and XCUITests. They cannot drift in *what* they compile — only in how targets
are declared. Add a source file and both pick it up; add a *target* and both manifests need it.

Three checks hold that together, and all three run in `./Scripts/ci.sh` and in the Linux CI job, as
the same program rather than a copy of one:

| Check | What it settles |
|-------|-----------------|
| [`Scripts/check_lockfiles.py`](Scripts/check_lockfiles.py) | `Package.resolved` and `Tuist/Package.resolved` pin the same versions. |
| [`Scripts/check_compiler_settings.py`](Scripts/check_compiler_settings.py) | The deployment floors match (fails); the Swift settings one manifest sets and the other does not (warns). |
| [`Scripts/check_module_edges.py`](Scripts/check_module_edges.py) | The module boundaries the documentation states — read from both manifests. |

The third is the newest and the one worth knowing about before you edit a `dependencies:` array.
Six documents state that `SpecImport` is unreachable from `ControlPlane` and from the CLI —
AGENTS.md, README.md, [ARCHITECTURE.md](docs/ARCHITECTURE.md), [CLI.md](docs/CLI.md),
[GRAPHQL.md](docs/GRAPHQL.md) and [ROADMAP.md](docs/ROADMAP.md) — and four places say the CLI links
neither Vapor nor GRDB: three of those documents and a comment above the target in `Project.swift`
itself. Every one of those sentences is a fact about two files, one line of either falsifies all of
them, and nothing used to notice. It walks the **transitive** closure, because adding `SpecImport`
to `Domain` would put the parsers in the CLI with every direct edge still absent, and it also
asserts the edges that must exist — so it cannot pass by having stopped seeing the graph.

If you deliberately change one of those boundaries, the check is the first thing to update; its
header lists the documents that have to move with it.

Anything SwiftPM compiles must also build on Linux, which is not macOS:

- `URLSession` lives in `FoundationNetworking`, not `Foundation`
- BSD socket calls live in `Glibc`, not `Darwin`, and some C types are wider
  (`SOCK_STREAM` is `__socket_type`; `timeval.tv_usec` is `__suseconds_t`)
- GRDB needs SQLite's C headers (`libsqlite3-dev`)

[`Tests/MockServerEngineTests/PlatformSockets.swift`](Tests/MockServerEngineTests/PlatformSockets.swift)
keeps those differences in one place. Verify rather than guess:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.2 \
  bash -c "apt-get update -qq && apt-get install -y -qq libsqlite3-dev && swift test"
```

## Test gates

```bash
# Everything, in one go — build, all suites, Release gate, UI tests, CLI end-to-end
./Scripts/ci.sh

# Every unit suite in one pass, through the aggregate scheme
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -skip-testing:MimicUITests

# One suite
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace test \
  -destination 'platform=macOS' -only-testing:DomainTests

# macOS UI tests
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
  -destination 'platform=macOS' -only-testing:MimicUITests

# Release gate — run after any SPM/Tuist change
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Release \
  CODE_SIGN_IDENTITY=- build
```

`Project.swift` declares exactly one scheme, `Mimic`. Everything else you can pass to `-scheme` —
`Mimic-Workspace` and one per module — is inferred by Tuist, and the inferred per-module schemes do
carry their `<Module>Tests` target: `Scripts/run_full_test_suite.sh` runs `xcodebuild -scheme Domain
test` and six more, and README's coverage section is generated from the `.xcresult` bundles they
produce. (This file used to claim the opposite, which is why `Mimic-Workspace` was presented as the
only way to run a unit suite. Prefer it because it covers everything in one pass, not because the
others cannot test.) `xcodebuild -workspace Mimic.xcworkspace -list` prints what was actually
generated.

**The CLI end-to-end check is part of `./Scripts/ci.sh` now, as its last step.** It can still be run
on its own:

```bash
./Scripts/run_cli_e2e.sh   # launches Mimic headless against a throwaway store
```

It covers a seam nothing else does — process launch, discovery, real sockets. What kept it out of the
gates was that it exercised whatever `mimic` and `Mimic.app` it could *find*, which by default is the
installed build rather than the one you just compiled: no `xcodebuild` step passed
`-derivedDataPath`, so the products landed outside the checkout while the script looks for
`*Build/Products*` inside it, and it fell back to `PATH`. `./Scripts/ci.sh` builds into
`.artifacts/DerivedData` inside the checkout and hands the script `MIMIC_BIN` and `MIMIC_APP_PATH`
from the Debug products it just produced, checking both exist first.

Run on its own after the commands above, it resolves both by searching again — those commands pass no
`-derivedDataPath` either — so set `MIMIC_BIN` and `MIMIC_APP_PATH` yourself, or the green result is
about a release you are not working on. The macOS CI job runs it too, and gates on it — it landed
non-gating for a single round, on the grounds that no machine had ever executed it, and that round
passed.

It is safe to run on a machine with Mimic open, which it did not use to be: it stops the instance it
launched by the pid `mimic app start` reported, and it exports `MIMIC_CONTROL_FILE="$WORK/control.json"`
so the launched instance advertises itself inside its own temporary directory instead of overwriting
the shared `control.json`. The old cleanup trap called `mimic app stop`, which reads that shared file
and signals whatever pid it names — it quit developers' own instances, on every exit path.

## Conventions

**Keep the rules in one place.** Adding an operation means adding a `ControlCommand` case, a matching
`CommandKind` case, a `scope` for it, and handling it in `ProjectCommandExecutor` if it is
project-scoped. The window, the CLI and the HTTP API all call that, so they cannot disagree. Never
implement the same rule twice. Three more steps are easy to miss: a `CommandCatalog` descriptor, and
a sample in each of the two lists the sweeps run on — `HostCommandSweepTests.sample(for:)` (which
fails the *build*, being a `default`-free switch over `CommandKind`) and `ControlCommandSamples.all`
in `DomainTests` (which fails the suite).

**What the compiler enforces is narrower than it looks.** `ControlCommand.kind` and
`CommandKind.scope` have no `default:`, so a new command cannot compile until it is named and
classified. The switches that *dispatch* it — `ProjectCommandExecutor.apply` and
`AppControlHost.perform` — end in a `default:` that throws at runtime naming the command; closing
them would mean re-listing every case each one declines, which is the hand-maintained duplication
`CommandKind.scope` exists to remove.

Sweeps over `CommandKind.allCases` cover the gap instead, and a new command has to survive all of
them: the executor from both sides (`DomainTests`), the host with and without a project open
(`HostCommandSweepTests`), the catalog, and the CLI, where `ControlTransportTests` requires some
`mimic` invocation to emit every kind.

A host-scoped command — one about server lifecycle, project selection, the journey cursor or the log,
which no pure function of the project can express — goes to `AppControlHost`, the one `ControlHost`
in production: `mimic daemon start` launches `Mimic.app` with `MIMIC_HEADLESS=1`, headless being a
mode of the app rather than a second process. (The unreachable second host the module used to carry
was deleted by the owner's decision — the account is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#one-host).)

**Spec import is the deliberate hole in that surface.** `SpecImport` is linked by the app — by
`AppFeatures` and by the app target — and by neither `ControlPlane` nor `MimicCLICore`, so HAR and
OpenAPI parsing has no command and no CLI verb. If you add one, you are adding a
dependency edge `ControlPlane` has never had — treat it as an architecture change, not a feature.

**Keep logic out of views.** Business rules belong in `Domain`; views stay declarative. If something
is worth a test, it belongs behind a testable boundary (`resolve`, `plan`, `ProjectCommandExecutor`).

**SwiftUI:** `@Observable` (not `@StateObject`/`@ObservedObject`), `.alert(_:isPresented:)`,
`Task.sleep` (never `DispatchQueue.main.asyncAfter`). Every interactive element gets an
`.accessibilityIdentifier()` and an `.accessibilityLabel()`.

**Tests:** Swift Testing (`@Test` / `#expect`) for units; XCTest with page objects for UI. Isolate
with `-MimicResetForTesting` and a per-run `MIMIC_DEFAULTS_SUITE`. Suites that bind a port
(`MockServerEngineTests`, `ControlPlaneTests`) disable the sandbox through their own entitlements.

**Test-only code is Debug-only.** Launch hooks live behind `#if DEBUG` so they never ship.

**Control API:** additive changes only within `v1`. Bump `ControlAPI.version` for a breaking change
to a command or response shape.

## Testing against real inputs

Three shipped bugs came from fixtures tidier than reality: a replayed `Content-Encoding: gzip` broke
every real HAR import; an appended `Content-Type` was emitted twice; and every Swagger fixture in the
suite declared `produces` inside the operation, while real specs overwhelmingly declare it once at the
document level — which the parser did not read, so those specs imported as plain text and, because
`.plainText` short-circuits the JSON body fallback, with no body either.

The tell is a fixture whose every instance agrees on something the format does not require: if all of
them put a field in the same place, the parser has only ever been asked to read it there. When a
feature consumes external input, add a case built from what a real server, browser or spec generator
actually produces —
[`Tests/SpecImportTests/RealCaptureTests.swift`](Tests/SpecImportTests/RealCaptureTests.swift) and
[`Tests/MockServerEngineTests/RealTrafficTests.swift`](Tests/MockServerEngineTests/RealTrafficTests.swift)
are the homes for HAR and traffic, and the OpenAPI/Swagger shape cases sit beside their parser in
[`Tests/SpecImportTests/OpenAPIParserTests.swift`](Tests/SpecImportTests/OpenAPIParserTests.swift).

## UI changes

A UI change isn't done until the XCUITests cover it and pass. Three things reliably bite:

1. **Launch through `UITestApp.launchAndBringToForeground`.** `XCUIApplication.launch()` returns when
   the process is running, which is not the same as having a window the accessibility layer can see —
   the app can come up hidden or behind the runner. A suite without the activation retry fails every
   test on "welcome screen should appear", which reads like a broken app rather than a broken test.
2. **Check what AppKit realizes an element as.** A SwiftUI `Menu` in a toolbar becomes a `MenuButton`,
   not a `Button`, so `app.buttons[…]` never matches it; a `DSEmptyState`'s text arrives as the
   element's `value`, not its label. When a query finds nothing, dump `app.debugDescription`.
3. **Never write `a.waitForExistence(t) || b.waitForExistence(t)`.** It waits out `a`'s entire timeout
   before it looks at `b`, so a short-lived `b` can come and go inside `a`'s wait. Use
   `UITestApp.waitForAny([a, b], timeout:)`.

## Releasing

The version lives in two places and both have to move together:

- `MARKETING_VERSION` in [`Project.swift`](Project.swift) — the app bundle's version
- `ControlAPI.releaseVersion` in `Sources/Domain/Control/ControlResult.swift` — what `mimic --version`
  reports, because a SwiftPM build of the CLI has no bundle to read

`ControlAPI.version` is separate and only moves for a breaking change to the control API.

Bump both, then build the installer. `Scripts/package_release.sh` reads `MARKETING_VERSION` itself,
so the version is never typed twice — but it builds from the generated project, so `tuist generate`
has to run after the bump or the bundle ships the old number.

```bash
./Scripts/ci.sh                                     # everything must be green first
tuist install && tuist generate --no-open
MIMIC_TEAM_ID=KW6369JJL9 MIMIC_NOTARY_PROFILE=mimic-notary ./Scripts/package_release.sh
```

That produces a signed, notarised and stapled `.artifacts/release/Mimic-X.Y.Z.pkg`, and finishes by
asking Gatekeeper for the verdict. Ship only if it prints `accepted`. Then:

```bash
gh release create vX.Y.Z .artifacts/release/Mimic-X.Y.Z.pkg --title "…" --notes-file …
```

Without `MIMIC_TEAM_ID` and `MIMIC_NOTARY_PROFILE` the script still builds, but the result is
unsigned and Gatekeeper blocks it — see the header of the script for what each variable does.

## Pull requests

1. Match the module boundaries in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
2. Add or update tests.
3. Make sure the Debug build, the unit suites, and the Release gate pass — `./Scripts/ci.sh` runs all
   three.
4. Update the docs a change makes wrong. [CHANGELOG.md](CHANGELOG.md) gets an entry for anything
   user-visible.
