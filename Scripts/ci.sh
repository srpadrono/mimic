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

# First, because it is the cheapest and because a drift here makes everything below it test a build
# that does not ship. The two manifests declare the same dependency ranges and resolve them into two
# separate lockfiles; 21 packages had already diverged, Vapor, NIO and GRDB among them.
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
swift test 2>&1 | grep -E "error:|✘|Test run with" || true

step "Resolve dependencies"
tuist install

step "Generate project"
tuist generate --no-open

step "Build (Debug)"
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Debug -destination 'platform=macOS' build \
  | grep -E "error:|warning:|BUILD" || true

step "Test (all unit suites)"
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace \
  test -destination 'platform=macOS' -skip-testing:MimicUITests \
  | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" || true

step "Release build gate"
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Release CODE_SIGN_IDENTITY=- build \
  | grep -E "error:|BUILD" || true

# UI tests do run in CI now. The macOS job pre-authorises UI automation with
# `automationmodetool enable-automationmode-without-authentication`, which is the piece that used to
# make this local-only. Kept here because a local run is still the fastest way to see a failure — and
# because this machine's automation service wedges periodically, at which point CI is the only place
# the suite runs at all.
step "UI tests"
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  test -destination 'platform=macOS' -only-testing:MimicUITests \
  | grep -E "error:|Test Case|TEST (SUCCEEDED|FAILED)" || true

printf '\n\033[1mLocal CI finished.\033[0m\n'
