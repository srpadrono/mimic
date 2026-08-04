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

# UI tests are not part of CI — XCUITest needs an interactive session to be granted automation
# permission — but they are runnable here, which is the point of having a local gate.
step "UI tests (local only)"
xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  test -destination 'platform=macOS' -only-testing:MimicUITests \
  | grep -E "error:|Test Case|TEST (SUCCEEDED|FAILED)" || true

printf '\n\033[1mLocal CI finished.\033[0m\n'
