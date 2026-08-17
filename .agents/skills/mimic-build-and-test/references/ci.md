# What CI actually covers

CI runs on every pull request and on every push to `main`, in **six job definitions and eight
jobs** — the UI one is a three-leg matrix. Both runners are free: GitHub does not meter standard
hosted runners on public repositories, macOS included.

| Job | Runner | Covers |
|-----|--------|--------|
| `linux` | `ubuntu-latest`, `swift:6.2` | `Package.swift`, the portable suites, and every cheap gate: house rules, the three manifest checks, documented counts, skill layout, UI-shard coverage, the coverage-writer self-test |
| `macos-checks` | `macos-26` | `tuist generate`, the Debug build, the app-level suites **with the coverage measurement**, the CLI end-to-end check (non-gating), the Release gate and its warning inventory |
| `macos-ui` (×3) | `macos-26` | The XCUITest suite, sharded across three runners by test class, each shard also measuring coverage |
| `ui-suite` | `ubuntu-latest` | Rolls the three shard results into one status check |
| `coverage` | `macos-26` | Pushes to `main` only, and downstream of all four macOS jobs: merges their four result bundles and emits the figures from the union |
| `record-coverage` | `ubuntu-latest` | Pushes to `main` only: publishes those figures as two shields.io endpoint payloads on the orphan `badges` branch, which README.md's badges read |

`record-coverage` is the only job holding `contents: write`, and it holds it precisely so that the
jobs compiling code out of a pull request do not — see the comments above it in the workflow.

**Required status checks** are `Build and test (Linux)`, `Build, unit suites, Release, CLI e2e
(macOS)` and `UI suite`. Neither coverage job belongs in that list: they run only on pushes to
`main`, so on a pull request they never report, and a required check that never reports blocks the
merge forever.

## Coverage: measured every run, merged, published to a branch of its own

Four jobs measure and a fifth merges. `macos-checks` runs the `Mimic-Workspace` scheme with
`-enableCodeCoverage YES` and `-skip-testing:MimicUITests`; each of the three `macos-ui` shards runs
its slice of XCUITest with the same flag. All four write a named `-resultBundlePath`, and the
`Coverage report` step in `macos-checks` prints its own per-target table into the **job summary** on
every run, pull requests included, so "how much of this is actually exercised" is a link away rather
than a script somebody has to remember to run.

On a push to `main`, each of the four tars its bundle and uploads it, and the `coverage` job merges
them.

### Why the bundles travel, and not the numbers

**Coverage is a set union over executed lines, not a sum.** A line the unit suites reach and a UI
test also reaches is one covered line in the union, not two. Four sets of nine per-target numbers
therefore cannot be combined into one set of nine by any arithmetic — the numbers have already thrown
away *which* lines. Adding double-counts and can exceed the denominator; taking the per-target
maximum discards everything one suite reached that the other did not. Only the line-level data
merges, and that lives in the `.xcresult`.

So the bundles move, as `.tar.gz` — a bundle is thousands of small files and `upload-artifact` posts
each one, which turns a directory upload into a step measured in tens of minutes, while a compressed
tarball is one file. `xcrun xcresulttool merge` does the union, and `Scripts/update_readme_coverage.py`
reads the merged bundle exactly as it read the single one.

The workflow comment above `Package the coverage bundle` records that this reverses an earlier
decision, and why: the old design handed nine numbers across as a job output and argued that moving
hundreds of megabytes to re-read nine numbers was waste. It was right about the cost and wrong about
the requirement.

### Where this can produce no gain, and how you would know

The app under test is sandboxed (`App/Mimic.entitlements`), and an instrumented binary writes its
`.profraw` to a path baked in at build time — under DerivedData, outside the app's container. If the
sandbox refuses that write, the shards' bundles carry coverage for the test target and nothing for
the app or the frameworks it links, which is where `AppFeatures` lives.

That is why the `coverage` job prints **two** tables into the summary: the unit-only figures beside
the merged ones. `AppFeatures` identical in both means the UI suite is still invisible to the
measurement, and the next move is the app's entitlements in CI rather than anything in this pipeline.
A union with an empty set is the same set, so the failure mode here is "no gain" — never a wrong
number.

### What the job refuses to publish

Two refusals, both ending in "the badges go on showing the last figures that were published":

- **Fewer bundles than `EXPECTED_COVERAGE_BUNDLES`.** A shard that died before writing one leaves a
  union missing everything that shard covered — a *lower* number, published with nothing to say
  anything is missing. That literal is `1 + the number of legs in macos-ui`, written down because a
  job cannot read another job's matrix, and `Scripts/check_ui_shards.py` fails the Linux job if it
  and the matrix disagree.
- **A merge that fails.** `xcresulttool merge` is the one command in that job whose behaviour could
  not be checked before it landed, so a future Xcode that spells it differently is a warning and a
  note in the summary, never a red X on a commit whose tests passed.

**Everything the Linux job runs** is still outside the figures, structurally: gathering coverage
needs the Xcode toolchain.

### The two figures go to two different places, on purpose

**The badges at the top of README.md are CI's.** `record-coverage` turns the figures into two
shields.io *endpoint* payloads with `Scripts/update_readme_coverage.py --from-json --emit-badges`,
and force-pushes them to the `badges` branch:

```
badges/app-coverage.json      {"schemaVersion": 1, "label": "line coverage",
                               "message": "96.82%", "color": "brightgreen"}
badges/module-coverage.json   {"schemaVersion": 1, "label": "modules at or above 95%",
                               "message": "6/8", "color": "red"}
```

Four keys, nothing else — no timestamp, no run URL. The colour comes from the same ladder the badges
have always used (95% brightgreen, 90% green, 80% yellow, below that red), and the module badge is
coloured by the *proportion* clearing the bar, so `6/8` is 75% and red while `8/8` is bright green.

**The first payload's file name does not describe what it carries, and that is deliberate.** It
published `Mimic.app coverage` once — the app *bundle* target, which is `App/Sources/MimicApp.swift`,
34 lines of `@main` entry point that `xccov` counts as 60 executable ones, and it read `46.67%` while
readers took it for a statement about the application. It carries the **weighted total across all
nine targets** now: covered lines over executable lines, computed once, not a mean of nine
percentages that would weight `ControlPlane`'s 413 lines the same as `AppFeatures`' 17,848.

Summing across targets is exact where summing across *runs* is not — the nine are disjoint sets of
source files in one already-merged report, so no line is in two of them. That is the same distinction
the merge above rests on, read the other way round.

`app-coverage.json` keeps its name because it is a URL README.md carries and the `badges` branch
serves: renaming it would leave a merged README pointing at a file the next run has not published
yet, so both badges would render shields.io's "invalid" placeholder for the length of a CI run. A
file name nobody reads is the cheaper inaccuracy.

The README links each through `https://img.shields.io/endpoint?url=…`, percent-encoded, at
`raw.githubusercontent.com/srpadrono/mimic/badges/<file>`. **Nothing in the tracked tree moves when
the badges do**, which is the whole point.

**The detailed per-target block between the `coverage:generated` markers is a local run's.**
`./Scripts/run_full_test_suite.sh` on a Mac writes it and is its only writer — by design now, not by
accident: `--from-json` refuses to run without `--emit-badges`, so no CI path can reach the README at
all. Expect the block to be older than the badges; the block's own provenance line says so.

### Why an orphan branch and not a bypass on `main`

The job used to rewrite README.md and push it to `main`. **Every push it ever made was refused**,
across six merges, while the job itself went green:

```
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: - Changes must be made through a pull request.
! [remote rejected] HEAD -> main (protected branch hook declined)
##[warning]Could not push the coverage update to main — the diff is in the job summary.
```

That is a rule, not a lost race: `main` takes changes only through a pull request and the Actions bot
is not exempt, so the retry-after-rebase the old step did could never have helped. Two ways out
existed — let the bot bypass the rule, or put the figures where the rule does not apply. **The owner
declined to weaken `main`'s protection for a badge**, so the badges moved.

`badges` is an **orphan** branch: created by the job if absent, no history from `main`, no source in
it, nothing that could need reviewing. Each run builds one parentless commit holding exactly the two
JSON files and force-pushes it, so the branch never accumulates history and stays a few hundred bytes
for the life of the repository. The recipe is worth reading once, because one step in it surprises
people: `git checkout --orphan` starts the branch with no parent but **keeps `main`'s files staged**,
so `git rm -r --cached .` clears the index (touching nothing on disk) before the two payloads are
added. The payloads are written to a `mktemp -d` outside the checkout, both because `.artifacts/` is
gitignored and `git add` would refuse them, and because they have to survive that index clear.

The branch name is written down **once**, in `Scripts/update_readme_coverage.py`, beside the URL
builder that produces what README.md must link. The workflow asks for it
(`--print-badge-branch`) rather than repeating it, and `--self-test` pins the two URLs to literals
so moving the branch fails the gate instead of silently 404ing both badges.

### What is deliberate about the job

- **It is a separate job, and the only one in the workflow holding `contents: write`.** The macOS
  jobs compile and run code out of a pull request; a write token there would widen the blast radius
  of anything going wrong in one to "can push". This job runs one stdlib Python script and some git —
  no build, no test, no repository code.
- **A few hundred bytes cross into this job, not a bundle.** The `coverage` job emits the merged
  figures as JSON (`--emit-json`) and hands them on as a job output. The bundles themselves stop
  there, on macOS, because merging them needs `xcresulttool` and nothing after the merge does — which
  is what lets the publishing run on Linux with a write token and no Xcode.
- **Nothing generated carries a timestamp, run number or run URL.** The branch is force-pushed to one
  commit regardless, so this no longer protects CI from anything — but the README block is still a
  pure function of the figures, because a *human* commits that one and an unchanged local measurement
  must leave the file byte-identical rather than dirtying the tree.
- **No `[skip ci]`, and its absence is the point.** The marker was load-bearing when this pushed to
  `main`: without it the commit triggered the workflow that wrote it. The `push:` trigger names
  `branches: [main]`, so a push to `badges` matches nothing. Restore a push to `main` and the marker
  has to come back with it.
- **It publishes; it never gates.** The step is `continue-on-error`, and it writes both payloads into
  the job summary *before* it touches git — so a failed publish leaves the figures on the run page
  and the badges showing whatever was last published. It never reddens a commit whose tests passed.

**shields.io caches an endpoint response for a few minutes.** A badge that still shows the previous
figure right after a merge is the cache, not a failed publish; check the raw URL before investigating
the job.

**No coverage floor is enforced, deliberately.** A threshold picked before anybody has seen the
number is either so low it never fires or red on the run that introduces it. Measuring first, then
setting the floor against a baseline, is the order.

The half of `update_readme_coverage.py` that needs no Mac — the badge URLs, the badge payloads, the
colour ladder, the JSON round trip, the block rewriter and every refusal — is covered by
`python3 Scripts/update_readme_coverage.py --self-test`, which the Linux job runs beside the other
checkers. Every expected value in it is written out longhand; nothing asks a function under test what
the right answer is.

## Why the macOS work is split the way it is

There used to be one macOS job running strictly in sequence, and run #87 measured it at about **96
minutes**, of which XCUITest alone was about **80**. The Release gate and the end-to-end check sat
behind the UI suite for no reason at all. Splitting the non-UI work out and sharding the UI suite
brings a run to about **30 minutes**, with the first red — a compile break or a unit failure — inside
ten.

Measured, rather than predicted. Run #89 (62b80e7) was the first real run of the sharded workflow,
with four shards:

| Job | Run #89, four shards | Now, three shards |
|-----|---------------------:|------------------:|
| `linux` | 2m20 | ~2m20 |
| `macos-checks` | 19m43 | ~19m43 |
| UI shard 1 | 21m18 (40 tests) | ~28m (51 tests) |
| UI shard 2 | 19m23 (38 tests) | ~29m (53 tests) |
| UI shard 3 | 23m49 (39 tests) | ~30m (54 tests) |
| UI shard 4 | **queued 19m26**, then ~22m (41 tests) | — |
| **Wall clock** | **~43m** | **~30m** |

The saving is not from running less — it is the same 158 tests — it is from stopping asking for a
fifth concurrent macOS job. Shard 3's 39 tests in a 22m42 step that also contains the build and the
test-target compile give the constant the right-hand column is derived from: **about 26 seconds per
UI test**.

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
- **Four macOS jobs, because four is the concurrency this repository was observed to get.** GitHub
  *documents* the concurrent-macOS-job cap as five on Free, Pro and Team (50 on Enterprise Cloud) — a
  much smaller cap than the 20/40/60 on standard runners — and the workflow was first written against
  that five: one `macos-checks` plus four shards. **Run #89 ran four.** Four jobs started together at
  22:01:49; the fifth started 19m26 later, two seconds after the first one finished and freed a slot.
  Exceeding the cap queues rather than fails, and a queued shard lands at roughly twice the shard
  time, which is exactly what happened. The claim worth carrying forward is the observation and not
  the documentation: **documented five, observed four, and a fifth macOS job waits about a shard's
  length.** The documented figure may be right in general and wrong for this account or this runner
  pool; one run is enough to design against and not enough to call the docs wrong. Before adding a
  fifth macOS job — another shard, or the Release gate split out of `macos-checks` — expect it to
  queue, and bring a measurement rather than the documented number. That is also why the Release gate
  is not a job of its own: it would cost a shard slot and lengthen the run.

  **The `coverage` job is a fifth macOS job and does not queue, which sharpens the rule rather than
  breaking it.** The cap is on jobs running *at the same time*; that one declares
  `needs: [macos-checks, macos-ui]`, so it starts only once all four have finished and returned their
  slots. It asks for a slot that is free by construction. The question to ask of a new macOS job is
  therefore not "is it the fifth" but "does it run beside the other four or after them" — beside
  costs about a shard's length, after costs only its own.
- **Each shard builds for itself** rather than downloading products from a shared
  `build-for-testing` job. The shards run concurrently, so the ~5-minute Debug build was never on the
  critical path more than once; building once would move it onto a *serial* job ahead of every shard
  and add a tar, an upload and three downloads. Build-once saves runner minutes, which this repository
  is not billed for, and risks a code signature that does not survive the round trip — which presents
  as a broken suite, not a broken artifact.

## The shard split is checked, not remembered

Sharding by `-only-testing:MimicUITests/<Class>` introduces a failure that the single job could not
have: **a class no shard names never runs, and every shard is green.** `Scripts/check_ui_shards.py`
runs in the Linux job and in `Scripts/ci.sh`, and fails on a class in no shard, a class in two, and a
shard naming a class that no longer exists (which `xcodebuild` reports as "no tests to run", exit 0).
It reads the workflow as text and `MimicUITests/` as text — no PyYAML, because the Linux container
installs `python3-minimal`.

It has a fourth verdict, one level up and the same shape: **`EXPECTED_COVERAGE_BUNDLES` disagreeing
with the shard count.** The `coverage` job merges one bundle per test-running job and cannot count
the shards for itself, since a job cannot read another job's `matrix`, so the total is a literal.
Add a fourth shard and leave the literal at 4 and that job merges three shards' coverage believing it
has all of them, publishing a figure lower than the truth with nothing anywhere to say a shard is
missing. Lower the literal and it refuses forever. Both are silent; this makes them a red Linux job.

`--self-test` drives all of it over a workflow and a suite tree invented inside the script — never
read off disk, never produced by the parsers — which is what makes it evidence about them.

Today's split is **51 / 53 / 54** across the ten classes, against an ideal third of 52.7, balanced by
**test count** — a proxy for time rather than time itself, and a defensible one since nearly every
test launches the app and per-test cost is dominated by launch. Run #89 supports the proxy without
vindicating it: 40 / 38 / 39 tests took 21m18 / 19m23 / 23m49, so the ordering does not track the
counts exactly, but the spread is small. An exhaustive search of every way of dealing the ten classes
onto three shards puts the best achievable spread at 2 (52 / 52 / 54); this split takes 3 and spends
the extra test — about 26 seconds — on shards whose names describe what they run. To rebalance from
real data, take a shard's `xcresult-ui-N` artifact and read the per-test durations out of it:

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
XCUITest suite**, in three shards. The image label is load-bearing on both — macOS 26 and Swift 6.2
are the compile floor, not a preference.

Four things about the macOS jobs are worth knowing before you edit them:

- **The setup lives in a composite action.** `.github/actions/macos-setup` holds what all four macOS
  jobs do before they build: Xcode and Swift versions, `automationmodetool`, Tuist at the pinned
  `mise.toml` version, its dependency cache, the `Tuist/Package.resolved` drift check, and `tuist
  generate`. Four pasted copies of those seven steps and their comments is the duplication AGENTS.md
  names outright. Two constraints when editing it: every `run:` step needs an explicit `shell: bash`,
  and `continue-on-error:` is a workflow-level key that composite steps do not take — end a
  diagnostic in `|| true` instead.
- **`Scripts/print_test_failures.sh` is how a failure gets read.** It prints compile errors out of
  the build log first (an xcresult cannot carry one — a test target that fails to build produces a
  bundle with `totalTestCount: 0`), then every failure with its message, file and line out of the
  newest bundle it was handed. Both test-running job kinds call it on `failure()`, which is why it is
  a script rather than forty lines of embedded Python pasted four times. It always exits 0.

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
machine rather than in three shards on three**, which is both why it takes about eighty minutes here
against CI's thirty and why `check_ui_shards.py` is the only thing that can see a missing shard
entry from a laptop. Read it rather than treating a green local run as a green CI run.

