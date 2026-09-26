#!/bin/zsh
# Run local gates with this machine's Swift toolchain. CI separately checks Linux and UI shards.
# Full UI coverage runs in CI's isolated shards; local UI checks select the affected methods.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mimic-ci.XXXXXX")"

DERIVED_DATA=".artifacts/DerivedData"

run_step() {
    local step_name=$1 filter=$2
    shift 2
    local logfile="$LOG_DIR/$step_name.log"
    local rc=0

    set +e
    "$@" 2>&1 | tee "$logfile" | grep -E "$filter"
    # Read zsh's 1-indexed pipeline status before another command overwrites it.
    rc=${pipestatus[1]}
    set -e

    if (( rc != 0 )); then
        printf '\n\033[1;31m%s failed (exit %d).\033[0m\nFull output: %s\n' "$step_name" "$rc" "$logfile"
        exit $rc
    fi
}

step "Lockfiles agree"
python3 Scripts/check_lockfiles.py --self-test

step "Compiler settings"
python3 Scripts/check_compiler_settings.py --self-test

step "Module edges"
python3 Scripts/check_module_edges.py --self-test

step "Portable modules (swift test — macOS toolchain, not the Linux container)"
run_step portable-modules "error:|✘|Test run with" \
  swift test

git diff --exit-code -- Package.resolved \
  || { printf '\n\033[1;31mPackage.resolved differs from the commit (diff above).\033[0m\nIf `swift test` re-resolved it, the suite that just passed ran against versions that are not in the commit. If you changed it yourself, commit it. Either way Tuist/Package.resolved has to move with it — Scripts/check_lockfiles.py is what says whether they still agree.\n' >&2; exit 1; }

step "Resolve dependencies"
tuist install

git diff --exit-code -- Tuist/Package.resolved \
  || { printf '\n\033[1;31mTuist/Package.resolved differs from the commit (diff above).\033[0m\nIf `tuist install` re-resolved it, the workspace generated below is not the one the commit describes. If you changed it yourself, commit it. Either way Package.resolved has to move with it — Scripts/check_lockfiles.py is what says whether they still agree.\n' >&2; exit 1; }

step "Generate project"
tuist generate --no-open

step "Build (Debug)"
run_step build-debug "error:|warning:|BUILD" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY=- build

step "Test (all unit suites)"
rm -rf .artifacts/coverage
mkdir -p .artifacts/coverage
run_step test-units "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic-Workspace \
  test -destination 'platform=macOS' -skip-testing:MimicUITests \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage YES \
  -resultBundlePath .artifacts/coverage/UnitTests.xcresult \
  CODE_SIGN_IDENTITY=-

python3 Scripts/update_readme_coverage.py \
  --result-bundle .artifacts/coverage/UnitTests.xcresult || true

step "Release build gate"
run_step build-release "error:|BUILD" \
  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic \
  -configuration Release -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY=- build

step "UI coverage is a CI gate"
printf 'Full UI tests run in CI shards. For local UI changes, run only the affected -only-testing:MimicUITests/Class/testMethod selectors.\n'

step "House rules"
Scripts/check_house_rules.sh --self-test
Scripts/check_house_rules.sh

step "Documentation and test targets"
python3 Scripts/check_doc_counts.py --self-test
python3 Scripts/check_doc_counts.py

step "UI shards cover every UI test method"
python3 Scripts/check_ui_shards.py --self-test
python3 Scripts/check_ui_shards.py

step "Script regressions"
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'

step "Coverage writer self-test"
python3 Scripts/update_readme_coverage.py --self-test

step "CLI end-to-end (launch, discovery, real sockets)"
PRODUCTS="$ROOT_DIR/$DERIVED_DATA/Build/Products/Debug"
if [[ ! -x "$PRODUCTS/mimic" || ! -d "$PRODUCTS/Mimic.app" ]]; then
    printf '\n\033[1;31mDebug products are not in %s.\033[0m\n' "$PRODUCTS"
    printf 'The Mimic scheme builds Mimic.app and mimic together, so this is a -derivedDataPath problem rather than a failure of the check.\n'
    exit 1
fi
run_step cli-e2e 'error|fail|== ' \
    env MIMIC_BIN="$PRODUCTS/mimic" MIMIC_APP_PATH="$PRODUCTS/Mimic.app" Scripts/run_cli_e2e.sh

printf '\n\033[1mLocal non-UI gates passed. Full UI coverage remains a CI gate.\033[0m\nFull output: %s\n' "$LOG_DIR"
