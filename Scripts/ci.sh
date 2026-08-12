#!/bin/zsh
# Runs exactly what CI runs, locally.
#
# Exists so the gate is reproducible on a laptop — useful before pushing, and essential while the
# hosted runners are unavailable. Keep this in step with .github/workflows/ci.yml; if they drift, the
# one that catches a bug first is the one that was actually run.

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
# lockfiles; 21 packages had already diverged, Vapor, NIO and GRDB among them.
step "Lockfiles agree"
python3 - <<'PY'
import json, sys
def pins(path):
    return {p['identity']: p['state'].get('version') for p in json.load(open(path))['pins']}
root, tuist = pins('Package.resolved'), pins('Tuist/Package.resolved')
drifted = {k: (root[k], tuist[k]) for k in root.keys() & tuist.keys() if root[k] != tuist[k]}
for name, (a, b) in sorted(drifted.items()):
    print(f"{name}: Package.resolved={a} Tuist/Package.resolved={b}")
if drifted:
    sys.exit(f"{len(drifted)} package(s) drifted — re-resolve both lockfiles to one set")
print(f"{len(root.keys() & tuist.keys())} shared packages agree")
PY

# The fast gate: everything that does not need Xcode. This is exactly what CI runs.
step "Portable modules (swift test — same as CI)"
run_step portable-modules "error:|✘|Test run with" \
  swift test

# These two already failed the script on their own — they are plain commands under `set -e`, with no
# pipeline to swallow the status — so they are left alone.
step "Resolve dependencies"
tuist install

step "Generate project"
tuist generate --no-open

step "Build (Debug)"
run_step build-debug "error:|warning:|BUILD" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Debug -destination 'platform=macOS' build

step "Test (all unit suites)"
run_step test-units "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace \
  test -destination 'platform=macOS' -skip-testing:MimicUITests

step "Release build gate"
run_step build-release "error:|BUILD" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Release CODE_SIGN_IDENTITY=- build

# UI tests do run in CI now. The macOS job pre-authorises UI automation with
# `automationmodetool enable-automationmode-without-authentication`, which is the piece that used to
# make this local-only. Kept here because a local run is still the fastest way to see a failure — and
# because this machine's automation service wedges periodically, at which point CI is the only place
# the suite runs at all.
step "UI tests"
run_step test-ui "error:|Test Case|TEST (SUCCEEDED|FAILED)" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  test -destination 'platform=macOS' -only-testing:MimicUITests

# Last locally, first in CI — deliberately different, because the two runs answer different questions.
#
# CI wants the cheapest check first: a handful of greps costs a second and saves a macOS runner
# twenty minutes. A developer on a laptop wants the opposite. Running the style gate first and fatally
# means a stray `.textCase(` stops you from ever reaching the unit suites, so you cannot find out
# whether the code you just wrote actually works until the casing is clean — which is precisely
# backwards while you are still writing it. It stays fatal here, so this script can still go red; it
# simply does not stand in front of the compiler.
step "House rules"
Scripts/check_house_rules.sh

printf '\n\033[1mLocal CI finished — everything green.\033[0m\nFull output: %s\n' "$LOG_DIR"
