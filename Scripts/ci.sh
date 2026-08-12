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
#
# This compares the *union*, not the intersection. The first version iterated `root.keys() & tuist.keys()`,
# so a package present in one lockfile and absent from the other was never looked at — which is exactly
# the shape a dropped dependency takes. `codeeditorview` and `rearrange` are legitimately one-sided
# (Tuist builds DesignSystem, which links CodeEditorView, which pulls Rearrange; Package.swift declares
# no SwiftUI target for either to attach to), so they are allowlisted by name and the allowlist is
# itself checked for staleness. The body below is character-for-character the one in
# .github/workflows/ci.yml, so a diff between the two files shows drift at a glance.
step "Lockfiles agree"
python3 - <<'PY'
import json, sys
TUIST_ONLY, ROOT_ONLY = {'codeeditorview', 'rearrange'}, set()
def pins(path):
    return {p['identity']: p['state'].get('version') for p in json.load(open(path))['pins']}
root, tuist = pins('Package.resolved'), pins('Tuist/Package.resolved')
problems = [f"{k}: Package.resolved={root[k]} Tuist/Package.resolved={tuist[k]}"
            for k in sorted(root.keys() & tuist.keys()) if root[k] != tuist[k]]
problems += [f"{k}: in Package.resolved ({root[k]}) and missing from Tuist/Package.resolved"
             for k in sorted(root.keys() - tuist.keys() - ROOT_ONLY)]
problems += [f"{k}: in Tuist/Package.resolved ({tuist[k]}) and missing from Package.resolved"
             for k in sorted(tuist.keys() - root.keys() - ROOT_ONLY - TUIST_ONLY)]
problems += [f"{k}: allowlisted as one-sided but is no longer — drop it from the allowlist"
             for k in sorted((TUIST_ONLY - (tuist.keys() - root.keys()))
                             | (ROOT_ONLY - (root.keys() - tuist.keys())))]
for line in problems:
    print(line)
if problems:
    sys.exit(f"{len(problems)} lockfile problem(s) — re-resolve both lockfiles to one set, "
             "or update the one-sided allowlist in this check")
print(f"{len(root.keys() & tuist.keys())} shared packages agree; "
      f"{len(TUIST_ONLY | ROOT_ONLY)} allowlisted as one-sided")
PY

# The other half of the same drift, and the half that is still open. The lockfiles now agree on
# versions; nothing makes the two manifests agree on how the compiler is configured. `Project.swift`
# sets four Swift settings in its shared base and `Package.swift` sets none, so `swift test` above is
# the looser gate — it accepts an implicit transitive import that Xcode rejects.
#
# It prints and moves on rather than failing, on purpose, and for the same reason the style gate sits
# at the bottom of this script: enabling the missing setting in `Package.swift` lights up every
# portable module at once, and stopping a local run over a known, tracked gap that nobody can close
# in passing is how a gate stops being read. The follow-up is to add
# `swiftSettings: [.enableUpcomingFeature(...)]` to `Package.swift`'s targets and fix the imports it
# surfaces in one change; this check goes quiet on its own when that lands.
step "Compiler settings"
python3 - <<'PY'
import os, pathlib, re
def warn(path, message):
    print(('::warning file=%s::%s' if os.environ.get('GITHUB_ACTIONS') else 'WARNING (%s): %s')
          % (path, message))
project = pathlib.Path('Project.swift').read_text()
# Whole-line comments are dropped so a feature merely *named* in prose cannot satisfy the
# check. Trailing comments are left alone on purpose: `//` also appears inside every
# `.package(url:)`, and cutting there would mangle the manifest this is reading.
package = "\n".join(l for l in pathlib.Path('Package.swift').read_text().splitlines()
                    if not l.lstrip().startswith('//'))
block = re.search(r'let sharedSettings.*?configurations:', project, re.S)
if block is None:
    warn('Project.swift', 'Could not find `sharedSettings`, so this check compared nothing. '
                          'Point it at wherever the shared base settings moved to.')
    raise SystemExit(0)
xcode = dict(re.findall(r'"(SWIFT_[A-Z_0-9]+)"\s*:\s*"([^"]*)"', block.group(0)))
# Spelled differently in the two manifests but meaning the same thing today. Printed every
# run, because that is a fact about the current tree rather than a property of either file.
EQUIVALENT_TODAY = {
    'SWIFT_VERSION':
        'swift-tools-version 6.0 already puts SwiftPM in language mode 6',
    'SWIFT_DEFAULT_ACTOR_ISOLATION':
        'every module Package.swift builds overrides this to "none" in Project.swift, and '
        'nonisolated is what SwiftPM defaults to — so the two agree by coincidence, not by '
        'construction',
}
# Deliberately NOT in the dict above. It is an Xcode umbrella that turns on a set of upcoming
# concurrency features, and Package.swift enables none of them — so calling it "equivalent today"
# would file a real divergence under the heading of things that are only spelled differently, which
# is the failure this whole check exists to stop.
UMBRELLA_WITHOUT_SWIFTPM_SPELLING = {
    'SWIFT_APPROACHABLE_CONCURRENCY':
        'an Xcode umbrella over several upcoming concurrency features; Package.swift enables none of '
        'them, so the Linux gate is genuinely looser here',
}
looser, unmapped, notes = [], [], []
for name, value in sorted(xcode.items()):
    if name.startswith('SWIFT_UPCOMING_FEATURE_'):
        # Xcode names an upcoming feature in UPPER_SNAKE, SwiftPM in UpperCamel. Deriving
        # it means a feature added to Project.swift is picked up with no edit here.
        feature = ''.join(w.capitalize()
                          for w in name[len('SWIFT_UPCOMING_FEATURE_'):].split('_'))
        token = 'enableUpcomingFeature("%s")' % feature
        if token not in package:
            looser.append('  %s = %s — Package.swift declares no .%s' % (name, value, token))
    elif name in UMBRELLA_WITHOUT_SWIFTPM_SPELLING:
        unmapped.append('  %s = %s — %s' % (name, value, UMBRELLA_WITHOUT_SWIFTPM_SPELLING[name]))
    elif name in EQUIVALENT_TODAY:
        notes.append('  %s = %s — %s' % (name, value, EQUIVALENT_TODAY[name]))
    else:
        unmapped.append('  %s = %s — this check has no SwiftPM mapping for it; add one'
                        % (name, value))
for line in looser + unmapped + notes:
    print(line)
if looser or unmapped:
    warn('Package.swift',
         '%d Swift setting(s) Project.swift applies that Package.swift does not, so this '
         'gate is looser than the compiler that ships the app. Reported, not enforced: '
         'turning them on here lights up every portable module at once, and closing those '
         'errors wants a toolchain to hand rather than a red pipeline to iterate against.'
         % (len(looser) + len(unmapped)))
else:
    print('Every Swift setting Project.swift applies is declared in Package.swift too.')
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

# Deliberately NOT run here: ./Scripts/run_cli_e2e.sh
#
# CONTRIBUTING.md lists it beside these gates, and it covers a seam nothing else does — process
# launch, discovery, real sockets. It still cannot join an unattended run, because its cleanup trap is
# not scoped to the instance it started. `mimic app stop` ignores MIMIC_CONTROL_URL and
# MIMIC_CONTROL_PORT entirely: `AppCommand.Stop` calls `ControlEndpointFileReader.discover()`, which
# reads the single `control.json` under Application Support and SIGTERMs whatever pid it names.
# Nothing redirects that file — the script's MIMIC_DATABASE_PATH isolates the store, not the discovery
# path — so on a machine with Mimic open, this script would quit the developer's own instance, and the
# headless run would have overwritten their discovery file on the way in. That is the same shape as
# the UI suite deleting `mimic.sqlite`, and the rule is the same: a convenience must never be able to
# compute its own target.
#
# So run it knowingly, when you have touched the CLI, the control plane or the launcher:
#
#   ./Scripts/run_cli_e2e.sh
#
# Making it stop the pid it launched, rather than whatever the shared discovery file names, is what
# would let it join this script and CI both. The matching note is in .github/workflows/ci.yml.

printf '\n\033[1mLocal CI finished — everything green.\033[0m\nFull output: %s\n' "$LOG_DIR"
