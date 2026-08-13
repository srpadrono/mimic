#!/bin/zsh
# Runs the CI gates locally: the macOS job command for command, the Linux job only in spirit.
#
# Exists so the gate is reproducible on a laptop — useful before pushing, and essential while the
# hosted runners are unavailable. It used to open by claiming it "runs exactly what CI runs", which
# was false in a way that mattered, so here is the precise version. Three differences, none of them
# fixable from inside this file:
#
#   - **`swift test` runs on this machine, not in the `swift:6.2` container.** Same sources, a
#     different platform: `URLSession` lives in `FoundationNetworking` there, the BSD socket calls
#     come from `Glibc` rather than `Darwin`, and some C types are wider — the differences
#     `Tests/MockServerEngineTests/PlatformSockets.swift` exists to hold. A green run here is not
#     evidence the Linux job will be green, and structurally cannot be. To check that, run what
#     AGENTS.md prescribes:
#
#         docker run --rm -v "$PWD":/src -w /src swift:6.2 swift test
#
#   - **The UI suite runs without `-retry-tests-on-failure -test-iterations 2`.** CI passes those
#     because a hosted runner under memory pressure will SIGKILL a random app launch, and a retry
#     tells that apart from a real assertion failure. Locally a flake is worth seeing rather than
#     retrying away, so this is a deliberate difference rather than a gap.
#
#   - **Runner setup is absent**, because it is not a gate: the SwiftPM and Tuist caches, and
#     `automationmodetool enable-automationmode-without-authentication`, which is what lets XCUITest
#     drive another app with nobody at the keyboard.
#
# Everything else is the same command with the same flags, ad-hoc signing included. The two manifest
# checks are the same *program*, not a copy of it: `Scripts/check_lockfiles.py` and
# `Scripts/check_compiler_settings.py` are invoked from here and from the workflow.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# Every build and test step below used to end `| grep -E "…" || true`, which meant this script could
# not go red. Two mistakes stacked. A pipeline reports only its *last* command's status, so the grep's
# result stood in for the build's — and then `|| true` discarded even that. A failing xcodebuild
# printed its `error:` lines, the script moved straight on to the next step, and it exited 0. README.md
# and CONTRIBUTING.md both name this as the gate to run before pushing, and the pre-release checklist
# says everything must be green first; what it was actually asserting was that the commands had run.
#
# The greps are worth keeping — raw xcodebuild output is thousands of lines nobody reads — so the
# output goes through `tee` to a log, the grep still filters what reaches the terminal, and the real
# status is read back out of `pipestatus`.
#
# Three zsh details this depends on, each checked rather than assumed, because getting one wrong would
# leave the script looking fixed and still incapable of failing:
#
#   - the array is `pipestatus`, lower case, and it is **1-indexed** — `[1]` is the command and `[3]`
#     is the grep. bash spells it `PIPESTATUS` and counts from 0; this script is not bash, and the
#     bash spelling would silently expand to nothing.
#   - it has to be read on the very next line. Anything in between overwrites it, `|| true` included:
#     `true` is itself a pipeline, so it resets the array to (0). That is why the old form could not
#     simply have a `${pipestatus[1]}` check bolted on after it — the check would have read the status
#     of `true` and passed forever.
#   - errexit must be off across the pipeline, because `grep` exits 1 when it matches nothing, and
#     matching nothing is what a clean build looks like. With `pipefail` on, that alone aborts the run.
#
# And `rc`, never `status`: in zsh `status` is a read-only synonym for `$?`, so assigning to it kills
# the script on the spot.
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimic-ci.XXXXXX")"

run_step() {
    local step_name=$1 filter=$2
    shift 2
    local logfile="$LOG_DIR/$step_name.log"
    local rc=0

    set +e
    "$@" 2>&1 | tee "$logfile" | grep -E "$filter"
    rc=${pipestatus[1]}
    set -e

    if (( rc != 0 )); then
        printf '\n\033[1;31m%s failed (exit %d).\033[0m\nFull output: %s\n' "$step_name" "$rc" "$logfile"
        exit $rc
    fi
}

# Before anything that compiles, because a drift here makes every step below it test a build that does
# not ship. The two manifests declare the same dependency ranges and resolve them into two separate
# lockfiles; 21 packages had already diverged, Vapor, NIO and GRDB among them. The program says why
# it compares the union rather than the intersection, and which two packages are legitimately
# one-sided.
step "Lockfiles agree"
python3 Scripts/check_lockfiles.py

# The other half of the same drift, and the half that is still half open. The deployment floors are
# now a gate — `MACOSX_DEPLOYMENT_TARGET` against `platforms:`, two literals, no toolchain needed to
# compare them, and they have already shipped eleven majors apart. The Swift settings stay a warning:
# `Project.swift` sets four in its shared base and `Package.swift` sets none, so `swift test` above is
# the looser gate — it accepts an implicit transitive import that Xcode rejects — and closing that
# wants a Swift 6.2 compiler to hand rather than a red pipeline to iterate against.
#
# Both halves live in one file that this script and the workflow both call. They used to be pasted
# into each, under a comment here claiming the copies were character-for-character identical; they
# were not, which is the whole argument for a file.
step "Compiler settings"
python3 Scripts/check_compiler_settings.py

# The fast gate: everything that does not need Xcode. The same suites the Linux job runs, on this
# machine's toolchain rather than in the `swift:6.2` container — see the header for what that cannot
# catch.
step "Portable modules (swift test — macOS toolchain, not the Linux container)"
run_step portable-modules "error:|✘|Test run with" \
  swift test

# The lockfile check at the top of this script compares the two lockfiles with each other, before
# anything is compiled. This compares one of them with what the run just did to it, which is a
# different failure: that check catches drift somebody committed, this one catches drift the build
# introduced. `swift test` builds first, and a build re-resolves and rewrites `Package.resolved`
# whenever a declared range resolves differently on this machine than on the one that committed it —
# silently, so the suite that just passed was run against versions nobody has reviewed.
#
# The message stops short of saying `swift test` did it, because unlike a CI checkout a laptop's tree
# can already be dirty: a developer who has just bumped a dependency and not yet committed sees this
# too, and telling them the build did something they did it themselves would be a lie in the one
# place a person is looking for the truth.
git diff --exit-code -- Package.resolved \
  || { printf '\n\033[1;31mPackage.resolved differs from the commit (diff above).\033[0m\nIf `swift test` re-resolved it, the suite that just passed ran against versions that are not in the commit. If you changed it yourself, commit it. Either way Tuist/Package.resolved has to move with it — Scripts/check_lockfiles.py is what says whether they still agree.\n' >&2; exit 1; }

# These two already failed the script on their own — they are plain commands under `set -e`, with no
# pipeline to swallow the status — so they are left alone.
step "Resolve dependencies"
tuist install

# The other half, and the same reasoning: `tuist install` is a SwiftPM resolve under another name,
# so it rewrites `Tuist/Package.resolved` on the same trigger. Checked here rather than after
# `tuist generate` because everything below is built from the workspace that generate produces out
# of whatever this resolve decided.
git diff --exit-code -- Tuist/Package.resolved \
  || { printf '\n\033[1;31mTuist/Package.resolved differs from the commit (diff above).\033[0m\nIf `tuist install` re-resolved it, the workspace generated below is not the one the commit describes. If you changed it yourself, commit it. Either way Package.resolved has to move with it — Scripts/check_lockfiles.py is what says whether they still agree.\n' >&2; exit 1; }

step "Generate project"
tuist generate --no-open

# `CODE_SIGN_IDENTITY=-` on all four xcodebuild steps, matching the workflow. It was on the Release
# gate here and nowhere else, which made the three steps above it the only commands in either runner
# that could reach for the project's DEVELOPMENT_TEAM certificate — so a signing failure was a thing
# only a laptop could produce, and only under the gate that is supposed to mirror CI exactly.
step "Build (Debug)"
run_step build-debug "error:|warning:|BUILD" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- build

# Coverage rides along with the unit suites, with the same two flags and the same bundle path the
# workflow uses. Not for the sake of symmetry: this script's contract, stated in its header, is that
# it runs the macOS job's commands with the macOS job's flags, so the one step in that job which
# measures something would otherwise be the one step this script does not reproduce — and the number
# a reviewer reads in a job summary would have no local counterpart to check it against.
step "Test (all unit suites)"
rm -rf .artifacts/coverage
mkdir -p .artifacts/coverage
run_step test-units "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace \
  test -destination 'platform=macOS' -skip-testing:MimicUITests \
  -enableCodeCoverage YES \
  -resultBundlePath .artifacts/coverage/UnitTests.xcresult \
  CODE_SIGN_IDENTITY=-

# Report-only, and `|| true` on purpose: the suites above have already passed by the time this runs,
# and failing the local gate because a result bundle could not be *read* would be reporting a
# reporting problem as a test failure. The same reasoning as `continue-on-error` on the workflow's
# coverage step. It prints its own reason when it cannot produce a table.
#
# This does not touch README.md. Rewriting the two badges and the generated section is still
# `Scripts/run_full_test_suite.sh`'s job — it measures each module through its own scheme, which is
# a different and slower measurement than this one workspace-wide run.
python3 Scripts/update_readme_coverage.py \
  --result-bundle .artifacts/coverage/UnitTests.xcresult || true

step "Release build gate"
run_step build-release "error:|BUILD" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Release CODE_SIGN_IDENTITY=- build

# UI tests do run in CI now. The macOS job pre-authorises UI automation with
# `automationmodetool enable-automationmode-without-authentication`, which is the piece that used to
# make this local-only. Kept here because a local run is still the fastest way to see a failure — and
# because this machine's automation service wedges periodically, at which point CI is the only place
# the suite runs at all.
# Without CI's `-retry-tests-on-failure -test-iterations 2`, deliberately: those are there for a
# hosted runner SIGKILLing an app launch under memory pressure, and locally a flake is worth seeing.
step "UI tests"
run_step test-ui "error:|Test Case|TEST (SUCCEEDED|FAILED)" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  test -destination 'platform=macOS' -only-testing:MimicUITests \
  CODE_SIGN_IDENTITY=-

# Last locally, first in CI — deliberately different, because the two runs answer different questions.
#
# CI wants the cheapest check first: a handful of greps costs a second and saves a macOS runner
# twenty minutes. A developer on a laptop wants the opposite. Running the style gate first and fatally
# means a stray `.textCase(` stops you from ever reaching the unit suites, so you cannot find out
# whether the code you just wrote actually works until the casing is clean — which is precisely
# backwards while you are still writing it. It stays fatal here, so this script can still go red; it
# simply does not stand in front of the compiler.
step "House rules"
# The scanner before the tree, because a linter with no test for its own scanner reports "no
# violations" for whatever reason it likes — and this one has now had two reasons. `--self-test`
# plants every rule in a throwaway file and asserts each spelling is reported:
#
#   - behind a URL in a string literal, the case that made the whole check evadable for as long as it
#     stripped comments with `sed 's|//.*||'`;
#   - spaced and module-qualified, the case that made it evadable by a space bar. `.textCase
#     (.uppercase)`, `SwiftUI.Alert(…)` and `DispatchQueue . main . asyncAfter(…)`, planted together
#     as real code under `Sources/`, left a full scan of this tree reporting "6 house rules checked,
#     no violations" and exiting 0.
#
# Both runs matter and neither substitutes for the other: the first says the scanner can see, the
# second says the tree is clean. It costs a fraction of a second and it is the only thing standing
# between "no violations" and "no scan".
Scripts/check_house_rules.sh --self-test
Scripts/check_house_rules.sh

# The other thing a grep can settle, and the only one that is about a document rather than the code.
# README.md's Tests badge and Testing table are hand-maintained — the README says so — and they have
# twice claimed a figure the tree did not support. This recounts `@Test` and `func test`
# declarations per folder and fails if any number README states has drifted, printing the true ones.
#
# It settles the operation count the same way, from `CommandKind` rather than from anybody's memory
# of the five places it is written down; and it fails on a folder under `Tests/` that neither
# manifest declares, because a suite no build target names is a suite nobody runs and it looks
# exactly like one that does.
#
# Also in .github/workflows/ci.yml, and this comment used to argue at length that it should not be —
# that a contributor's pull request should go red for a defect in the code, not for a hand count in a
# document they may not own. That reasoning was wrong about which failure is cheaper. A count that is
# only checked before pushing is a count nobody checks, and this table has already drifted twice; the
# fix is one command whose output names the numbers to paste, and it takes seconds on a runner with
# no Swift involved. The README's coverage section still works the other way because populating it
# needs `Scripts/run_full_test_suite.sh` and a Mac, which is a different kind of cost.
step "Documented counts"
python3 Scripts/check_doc_counts.py

# Deliberately NOT run here: ./Scripts/run_cli_e2e.sh
#
# CONTRIBUTING.md lists it beside these gates, and it covers a seam nothing else does — process
# launch, discovery, real sockets. What used to keep it out was that its cleanup trap called
# `mimic app stop`, which reads the shared `control.json` and SIGTERMs whatever pid it names: on a
# machine with Mimic open, running it quit the developer's own instance. That is fixed — it now kills
# the pid `mimic app start` reported and writes its discovery file inside its own temporary directory
# via MIMIC_CONTROL_FILE — so what is left is not a safety problem but a plumbing one, in two parts:
#
#   - **It cannot find a CLI this script built.** No xcodebuild step here passes `-derivedDataPath`,
#     so the products land in the user's DerivedData, outside the checkout, while the script looks for
#     `find "$ROOT_DIR" … -path '*Build/Products*'`. The only thing that writes that shape inside the
#     tree is `Scripts/package_release.sh`, under `.artifacts/build/DerivedData`. Failing that, the
#     script falls back to whatever `mimic` is on PATH — which is an *installed* build, not this one.
#   - **The app is resolved separately from the CLI.** `AppLauncher.resolveExecutable` tries
#     `MIMIC_APP_PATH`, `/Applications/Mimic.app`, then `~/Applications/Mimic.app`. Wiring this up
#     means exporting two paths, not one, and both have to point at what this run just built rather
#     than at whatever is installed — otherwise a green e2e says nothing about the working tree.
#
# So run it knowingly, when you have touched the CLI, the control plane or the launcher:
#
#   ./Scripts/run_cli_e2e.sh
#
# The matching note is in .github/workflows/ci.yml, where the same two paths are the blocker.

printf '\n\033[1mLocal CI finished — everything green.\033[0m\nFull output: %s\n' "$LOG_DIR"
