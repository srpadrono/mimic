#!/bin/zsh
# Launches the build under test for the release regression gate (docs/RELEASE_REGRESSION.md) with a
# store, defaults suite, control port and discovery file of its own, so recording the scenarios never
# opens or changes the developer's own projects.
#
#   Scripts/release_regression.sh start [--fresh] <Mimic.app> <mimic>
#   Scripts/release_regression.sh stop
#
# `start` copies the app into the run's directory, gives the copy its own bundle identifier and an
# ad hoc signature without the sandbox (the shipping app cannot write outside its container), and
# opens it with its window through the given CLI. It keeps the run's store between starts, which is
# what the persistence scenario relaunches into; `--fresh` deletes it first. It also writes
# `env.sh`: `source` it in the Terminal used for the curl and CLI steps so `mimic` talks to this copy.
#
# This is the Scripts/run_cli_e2e.sh isolation, kept running for a person or an agent to drive.
#
#   MIMIC_REGRESSION_DIR           run directory (default ~/MimicRegression/<version>)
#   MIMIC_REGRESSION_CONTROL_PORT  control API port (default 47391)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

VERSION="$(grep -m1 '"MARKETING_VERSION"' "$ROOT_DIR/Project.swift" | sed -E 's/.*: *"([^"]+)".*/\1/')"
WORK="${MIMIC_REGRESSION_DIR:-$HOME/MimicRegression/$VERSION}"
CONTROL_PORT="${MIMIC_REGRESSION_CONTROL_PORT:-47391}"
SUITE="devxa.Mimic.Regression"

usage() { fail "usage: $0 start [--fresh] <Mimic.app> <mimic> | stop"; }

running_pid() {
  pgrep -f "$WORK/Mimic.app/Contents/MacOS/" 2>/dev/null | head -1 || true
}

case "${1:-}" in
  start)
    shift
    fresh=false
    if [[ "${1:-}" == "--fresh" ]]; then fresh=true; shift; fi
    [[ $# -eq 2 ]] || usage
    app="${1:A}"; cli="${2:A}"
    [[ -d "$app" ]] || fail "no app bundle at $app"
    [[ -x "$cli" ]] || fail "no mimic executable at $cli"
    [[ -z "$(running_pid)" ]] || fail "the regression copy is already running; quit it (⌘Q) or run '$0 stop'"
    if $fresh; then
      rm -rf "$WORK"
      defaults delete "$SUITE" >/dev/null 2>&1 || true
      defaults delete "$SUITE.App" >/dev/null 2>&1 || true
    fi
    mkdir -p "$WORK/videos"
    [[ -f "$WORK/token" ]] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$WORK/token"
    chmod 600 "$WORK/token"

    rm -rf "$WORK/Mimic.app"
    ditto "$app" "$WORK/Mimic.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SUITE.App" "$WORK/Mimic.app/Contents/Info.plist"
    codesign --force --deep --sign - "$WORK/Mimic.app" >/dev/null 2>&1
    cp "$cli" "$WORK/mimic"

    cat > "$WORK/env.sh" <<EOF
# Points \`mimic\` at the release regression copy. Source this file; do not run it.
export PATH="$WORK:\$PATH"
export MIMIC_APP_PATH="$WORK/Mimic.app"
export MIMIC_DATABASE_PATH="$WORK/mimic.sqlite"
export MIMIC_DEFAULTS_SUITE="$SUITE"
export MIMIC_CONTROL_PORT="$CONTROL_PORT"
export MIMIC_CONTROL_FILE="$WORK/control.json"
export MIMIC_CONTROL_TOKEN="\$(cat "$WORK/token")"
export MIMIC_REGRESSION_DIR="$WORK"
unset MIMIC_CONTROL_URL
EOF
    source "$WORK/env.sh"
    "$WORK/mimic" app start --wait-seconds 60
    printf '\nRegression copy of Mimic %s is running from %s.\n' "$VERSION" "$WORK"
    printf 'In the Terminal used for the scenarios: source %q\n' "$WORK/env.sh"
    printf 'Save recordings in %s\n' "$WORK/videos"
    ;;
  stop)
    pid="$(running_pid)"
    [[ -n "$pid" ]] || { echo "The regression copy is not running."; exit 0; }
    kill "$pid"
    for _ in {1..20}; do [[ -z "$(running_pid)" ]] && exit 0; sleep 0.3; done
    fail "the regression copy (pid $pid) did not exit"
    ;;
  *) usage ;;
esac
