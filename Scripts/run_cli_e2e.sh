#!/bin/zsh
# Exercise a headless app, CLI discovery, and a complete journey through real loopback sockets.
# Only the app launched here and files under WORK may be changed or stopped.

set -euo pipefail

CONTROL_PORT="${MIMIC_E2E_CONTROL_PORT:-18787}"
MOCK_PORT="${MIMIC_E2E_MOCK_PORT:-18080}"

[ -x "${MIMIC_BIN:-}" ] || { echo "Set MIMIC_BIN to the built mimic executable." >&2; exit 1; }
if [ -z "${MIMIC_APP_PATH:-}" ] || [ ! -d "$MIMIC_APP_PATH" ]; then
  echo "Set MIMIC_APP_PATH to the built Mimic.app." >&2
  exit 1
fi
for port in "$CONTROL_PORT" "$MOCK_PORT"; do
  if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "Port $port is in use; set MIMIC_E2E_CONTROL_PORT or MIMIC_E2E_MOCK_PORT." >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
export MIMIC_DATABASE_PATH="$WORK/mimic.sqlite"
export MIMIC_CONTROL_PORT="$CONTROL_PORT"
export MIMIC_CONTROL_FILE="$WORK/control.json"
export MIMIC_CONTROL_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
unset MIMIC_CONTROL_URL

MIMIC_PID=""

cleanup() {
  local rc=$?
  set +e
  if [ -n "$MIMIC_PID" ] && kill -0 "$MIMIC_PID" 2>/dev/null; then
    kill "$MIMIC_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if ! kill -0 "$MIMIC_PID" 2>/dev/null; then break; fi
      sleep 0.3
    done
  fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT

# The shipping app is sandboxed and cannot write to WORK. Run an ad-hoc signed copy
# without its entitlements, as the pass-through e2e harness does. Never alter the build.
ditto "$MIMIC_APP_PATH" "$WORK/Mimic.app"
codesign --force --deep --sign - "$WORK/Mimic.app" >/dev/null 2>&1
export MIMIC_APP_PATH="$WORK/Mimic.app"

echo "CLI: $MIMIC_BIN"
echo "App: $MIMIC_APP_PATH (test copy)"

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
start_output="$("$MIMIC_BIN" app start --headless --wait-seconds 60)" || fail "could not start Mimic"
# Stop only the pid reported by this launch; never use `mimic app stop` here.
MIMIC_PID="$(printf '%s\n' "$start_output" | sed -n 's/.*(pid \([0-9][0-9]*\).*/\1/p')"
if [ -z "$MIMIC_PID" ]; then
  fail "no pid in: $start_output
Something is already answering on control port $CONTROL_PORT. Stop it, or set MIMIC_E2E_CONTROL_PORT."
fi
echo "  ok   reachable (pid $MIMIC_PID)"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$MIMIC_CONTROL_FILE" ]; then break; fi
  sleep 0.2
done
if [ ! -f "$MIMIC_CONTROL_FILE" ]; then
  fail "the launched app did not write its discovery file to $MIMIC_CONTROL_FILE"
fi

echo "== scripting the journey from the product goal =="
"$MIMIC_BIN" project create "CLI e2e" --port "$MOCK_PORT" >/dev/null || fail "project create"
"$MIMIC_BIN" journey add-template retry-after-failure --name "Goal flow" --activate >/dev/null \
  || fail "add-template"
"$MIMIC_BIN" server start >/dev/null || fail "server start"
for _ in {1..200}; do
  if nc -z 127.0.0.1 "$MOCK_PORT" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
nc -z 127.0.0.1 "$MOCK_PORT" >/dev/null 2>&1 || fail "mock listener did not start on $MOCK_PORT"

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
