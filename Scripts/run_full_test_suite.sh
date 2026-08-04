#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$ROOT_DIR/Mimic.xcworkspace"
RESULTS_DIR="$ROOT_DIR/.artifacts/full-suite-results"
DESTINATION="platform=macOS"

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

run_coverage_test() {
  local scheme="$1"
  local result_name="$2"
  shift 2

  rm -rf "$RESULTS_DIR/$result_name.xcresult"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    test \
    -destination "$DESTINATION" \
    -enableCodeCoverage YES \
    -resultBundlePath "$RESULTS_DIR/$result_name.xcresult" \
    "$@"
}

run_plain_test() {
  local scheme="$1"
  local result_name="$2"
  shift 2

  rm -rf "$RESULTS_DIR/$result_name.xcresult"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    test \
    -destination "$DESTINATION" \
    -resultBundlePath "$RESULTS_DIR/$result_name.xcresult" \
    "$@"
}

# Per-module suites (each scheme reports coverage for its own framework).
run_coverage_test "Domain" "Domain"
run_coverage_test "MockServerEngine" "MockServerEngine"
run_coverage_test "Persistence" "Persistence"
run_coverage_test "ControlPlane" "ControlPlane"
run_coverage_test "MimicCLICore" "MimicCLICore"
run_coverage_test "DesignSystem" "DesignSystem"
run_coverage_test "SpecImport" "SpecImport"
# App + AppFeatures coverage is captured through the app test target (MimicTests).
run_coverage_test "Mimic" "MimicApp" -only-testing:MimicTests
run_plain_test "Mimic" "MimicUI" -only-testing:MimicUITests

python3 "$ROOT_DIR/Scripts/update_readme_coverage.py" \
  --readme "$ROOT_DIR/README.md" \
  --results-dir "$RESULTS_DIR"

echo "Full suite passed."
echo "Coverage results: $RESULTS_DIR"
echo "README coverage section updated."
