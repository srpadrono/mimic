#!/bin/zsh
# End-to-end check that the CLI can drive a complete journey without touching the UI.
#
# Launches Mimic headless against a throwaway store, scripts the canonical journey from the product
# goal, and asserts that the same route answers 500 then 200 depending on where the request falls.
# Exercises the seams a unit test cannot: process launch, discovery, HTTP, and real sockets.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
CONTROL_PORT="${MIMIC_E2E_CONTROL_PORT:-18787}"
MOCK_PORT="${MIMIC_E2E_MOCK_PORT:-18080}"

export MIMIC_DATABASE_PATH="$WORK/mimic.sqlite"
export MIMIC_CONTROL_PORT="$CONTROL_PORT"
export MIMIC_CONTROL_URL="http://127.0.0.1:$CONTROL_PORT"

# Prefer a freshly built CLI; fall back to one on PATH.
MIMIC_BIN="$(find "$ROOT_DIR" -type f -name mimic -perm -u+x -path '*Build/Products*' 2>/dev/null | head -1)"
if [ -z "$MIMIC_BIN" ]; then
  MIMIC_BIN="$(command -v mimic)" || {
    echo "Could not find the mimic binary. Build it with:" >&2
    echo "  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Debug build" >&2
    exit 1
  }
fi

cleanup() {
  "$MIMIC_BIN" app stop >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    fail "$1 — expected [$2], got [$3]"
  fi
}
code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$MOCK_PORT$2"; }

echo "== launching Mimic headless =="
"$MIMIC_BIN" app start --headless --wait-seconds 60 >/dev/null || fail "could not start Mimic"
echo "  ok   reachable"

echo "== scripting the journey from the product goal =="
"$MIMIC_BIN" project create "CLI e2e" --port "$MOCK_PORT" >/dev/null || fail "project create"
"$MIMIC_BIN" journey add-template retry-after-failure --name "Goal flow" --activate >/dev/null \
  || fail "add-template"
"$MIMIC_BIN" server start >/dev/null || fail "server start"

echo "== the same route answers differently by position =="
check "POST /login"                  "200" "$(code POST /login)"
check "GET /account-summary (first)" "500" "$(code GET /account-summary)"
check "GET /inbox"                   "200" "$(code GET /inbox)"
check "GET /account-summary (retry)" "200" "$(code GET /account-summary)"

echo "== restart rewinds the run =="
"$MIMIC_BIN" journey restart >/dev/null || fail "journey restart"
check "replays the failure" "500" "$(code POST /login >/dev/null; code GET /account-summary)"

echo "== held state lifts on demand =="
"$MIMIC_BIN" journey add-template maintenance-window --name "Maintenance" --activate >/dev/null \
  || fail "maintenance template"
check "held 503" "503" "$(code GET /account-summary)"
"$MIMIC_BIN" journey advance >/dev/null || fail "journey advance"
check "lifted"   "200" "$(code GET /account-summary)"

echo
echo "CLI end-to-end checks passed."
