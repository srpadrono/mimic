# What CI actually covers

CI runs on every pull request and on every push to `main`, in **five job definitions and eight
jobs** — the UI one is a four-leg matrix. Both runners are free: GitHub does not meter standard
hosted runners on public repositories, macOS included.

| Job | Runner | Covers |
|-----|--------|--------|
| `linux` | `ubuntu-latest`, `swift:6.2` | `Package.swift`, the portable suites, and every cheap gate: house rules, the three manifest checks, documented counts, skill layout, UI-shard coverage, the coverage-writer self-test |
| `macos-checks` | `macos-26` | `tuist generate`, the Debug build, the app-level suites **with the coverage measurement**, the CLI end-to-end check (non-gating), the Release gate and its warning inventory |
| `macos-ui` (×4) | `macos-26` | The XCUITest suite, sharded across four runners by test class |
| `ui-suite` | `ubuntu-latest` | Rolls the four shard results into one status check |
| `record-coverage` | `ubuntu-latest` | Pushes to `main` only: writes the measured coverage into README.md |

`record-coverage` is the only job holding `contents: write`, and it holds it precisely so that the
jobs compiling code out of a pull request do not — see the comments above it and above `Emit coverage
figures`. It needs `macos-checks` and **not** the UI shards, because coverage is measured in that job
and because this repository's UI suite is documented as ending red on a test that passed on its
retry; making the recording wait on the shards would mean the README updates only on runs where a
flake happened not to fire.

## Why the macOS work is split the way it is

There used to be one macOS job running strictly in sequence, and run #87 measured it at about **96
minutes**, of which XCUITest alone was about **80**. The Release gate and the end-to-end check sat
behind the UI suite for no reason at all. Splitting the non-UI work out and sharding the UI suite
brings a run to about **29 minutes**, with the first red — a compile break or a unit failure — inside
ten.

Three things about the split are load-bearing, and the workflow's header argues each at length:

- **Shards, never `-parallel-testing-enabled`.** Two independent reasons, either of which is
  sufficient. The suites share one store (`UITestSupport.databaseURL` is the fixed
  `mimic-uitests.sqlite`, and `resetApp` deletes it on every launch) and one defaults domain (the
  fixed `com.devxa.Mimic.UITests`, wiped in `setUpWithError`), so two workers on one machine destroy
  each other's state by construction. And this is a real macOS app rather than a simulator: parallel
  workers share one window server and one frontmost application, while these suites lean on
  `typeText`, `typeKey` and ⌘-click, which go to whichever app has focus. Separate machines dissolve
  both. Nothing in `MimicUITests` needed changing — the suites already use disjoint port ranges and
  already suffix `MIMIC_CONTROL_FILE` with the runner's pid.
- **Five macOS jobs, because GitHub caps concurrent macOS jobs at five** on Free, Pro and Team (50 on
  Enterprise Cloud) — a much smaller cap than the 20/40/60 on standard runners. Exceeding it queues
  rather than fails, and a queued shard lands at roughly twice the shard time, so five is a budget:
  one `macos-checks` plus four shards. That is also why the Release gate is not a job of its own —
  it would cost a shard slot and lengthen the run.
- **Each shard builds for itself** rather than downloading products from a shared
  `build-for-testing` job. The shards run concurrently, so the ~5-minute Debug build was never on the
  critical path more than once; building once would move it onto a *serial* job ahead of every shard
  and add a tar, an upload and four downloads. Build-once saves runner minutes, which this repository
  is not billed for, and risks a code signature that does not survive the round trip — which presents
  as a broken suite, not a broken artifact.

## The shard split is checked, not remembered

Sharding by `-only-testing:MimicUITests/<Class>` introduces a failure that the single job could not
have: **a class no shard names never runs, and every shard is green.** `Scripts/check_ui_shards.py`
runs in the Linux job and in `Scripts/ci.sh`, and fails on a class in no shard, a class in two, and a
shard naming a class that no longer exists (which `xcodebuild` reports as "no tests to run", exit 0).
It reads the workflow as text and `MimicUITests/` as text — no PyYAML, because the Linux container
installs `python3-minimal`.

Today's split is 40 / 38 / 39 / 41 across the ten classes, balanced longest-first by **test count**,
which is a proxy for time rather than time itself — a defensible one, since nearly every test launches
the app and per-test cost is dominated by launch. To rebalance from real data, take a shard's
`xcresult-ui-N` artifact and read the per-test durations out of it:

```bash
xcrun xcresulttool get test-results tests --path UITests.xcresult
```

Then edit the `matrix` in the workflow; nothing else has to move.

**Branch protection is configured by job name**, and `Build and test (macOS)` no longer exists. The
required checks are `Build, unit suites, Release, CLI e2e (macOS)` and `UI suite` — the latter exists
partly so that the required name survives any future reshuffle of the shards.

**Linux** builds through [`Package.swift`](../../../../Package.swift) rather than Tuist — the domain rules, mock
engine, persistence, control plane, spec import and CLI are plain Swift, so most of the suite reports
back in a couple of minutes. Both manifests declare those modules from the same directories, so they
cannot drift in what they compile, only in how targets are declared. What they *can* drift in is
dependency resolution: they resolve the same ranges into two separate lockfiles, and 21 packages —
Vapor, NIO and GRDB among them — had already diverged, so this job was passing against versions the
shipped `.pkg` does not contain. `Scripts/check_lockfiles.py` compares the two before the job builds
anything, and a second step fails if `swift build` *re-resolved* `Package.resolved` on the way past —
otherwise the versions the job tested are not the versions the commit names, and the drift check
would have passed on a file the build then rewrote. The macOS job holds `tuist install` to the same
rule for `Tuist/Package.resolved`.

Compiler settings are the other half, and `Scripts/check_compiler_settings.py` splits them by what a
disagreement costs. **The deployment floor fails**: `MACOSX_DEPLOYMENT_TARGET` in `Project.swift`
against `platforms:` in `Package.swift` are one fact written twice, they have already come apart, and
comparing two literals needs no toolchain. **The Swift settings warn.** `Project.swift`'s shared base
sets four; run the script and it prints where each stands — today
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` and `SWIFT_APPROACHABLE_CONCURRENCY` have no
SwiftPM counterpart, so Linux still accepts an implicit transitive import that Xcode rejects, while
`SWIFT_VERSION` and `SWIFT_DEFAULT_ACTOR_ISOLATION` are annotated as already-equivalent rather than
missing. Declaring the two on the SwiftPM side is the fix; it warns rather than fails because turning
them on lights up every portable module at once, and going red before anyone can iterate on the
errors helps nobody. The gap is visible on every run instead of silent, and the step goes quiet on
its own the day `swiftSettings:` lands.

**macOS** (`macos-26`) covers everything that needs Xcode, across two job definitions that run at the
same time. `macos-checks` does `tuist generate`, the Debug build, the app-level suites, the CLI
end-to-end check — non-gating, for the reason below — and the Release gate. `macos-ui` does **the
XCUITest suite**, in four shards. The image label is load-bearing on both — macOS 26 and Swift 6.2
are the compile floor, not a preference.

Four things about the macOS jobs are worth knowing before you edit them:

- **The setup lives in a composite action.** `.github/actions/macos-setup` holds what all five macOS
  jobs do before they build: Xcode and Swift versions, `automationmodetool`, Tuist at the pinned
  `mise.toml` version, its dependency cache, the `Tuist/Package.resolved` drift check, and `tuist
  generate`. Five pasted copies of those seven steps and their comments is the duplication AGENTS.md
  names outright. Two constraints when editing it: every `run:` step needs an explicit `shell: bash`,
  and `continue-on-error:` is a workflow-level key that composite steps do not take — end a
  diagnostic in `|| true` instead.
- **`Scripts/print_test_failures.sh` is how a failure gets read.** It prints compile errors out of
  the build log first (an xcresult cannot carry one — a test target that fails to build produces a
  bundle with `totalTestCount: 0`), then every failure with its message, file and line out of the
  newest bundle it was handed. Both test-running job kinds call it on `failure()`, which is why it is
  a script rather than forty lines of embedded Python pasted five times. It always exits 0.

- **`sudo automationmodetool enable-automationmode-without-authentication` is what makes XCUITest
  possible at all.** Since Monterey, macOS asks a human to approve UI automation before a runner may
  drive another app. Nobody is at the keyboard on CI, so without it the runner fails to initialise
  and reports `Timed out while enabling automation mode` with *zero tests executed* — which reads
  like a broken suite rather than a missing permission. The same message appears locally when the
  SIP-protected `automationmode-writer` service wedges; see the `mimic-ui-tests` skill.
- **Everything is signed ad-hoc (`CODE_SIGN_IDENTITY=-`).** The project carries a `DEVELOPMENT_TEAM`
  for local builds, and a hosted runner has none of that team's certificates. It does not need them:
  a macOS app only has to be signed *somehow* to launch.

This was not always possible. While the repo was private, every run died in about two seconds with
zero steps executed, on Linux and macOS alike, because of a billing block — which is why the triggers
used to be commented out and the macOS job disabled. Making the repo public resolved it.

`./Scripts/ci.sh` runs the same gates locally and is still the fastest way to check before pushing,
in this order: lockfiles, compiler settings, module edges, `swift test`, `tuist install && generate`,
the Debug build, every unit suite, the Release gate, the UI suite, `check_house_rules.sh --self-test`
followed by the real house rules scan, `check_doc_counts.py --self-test` followed by the real count
check, `check_skills.py`, `check_ui_shards.py --self-test` followed by the real shard check, and —
last, and gating here from the start — the CLI end-to-end check. The
three manifest checks near the top run before anything
compiles, `check_module_edges.py` among them, because a drift there makes every step below it test a
build that does not ship. Its own header names the four things it cannot reproduce — `swift test`
runs on this machine's toolchain rather than in the `swift:6.2` container, the UI suite runs without
CI's `-retry-tests-on-failure`, runner setup is absent, and **the UI suite runs in one pass on one
machine rather than in four shards on four**, which is both why it takes about eighty minutes here
against CI's twenty-nine and why `check_ui_shards.py` is the only thing that can see a missing shard
entry from a laptop. Read it rather than treating a green local run as a green CI run.

