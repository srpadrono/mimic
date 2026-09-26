#!/bin/zsh
# Exercise a headless app, CLI discovery, and a complete journey through real loopback sockets.
# Owns its app copy, temporary files and unique preferences suite.

set -euo pipefail

CONTROL_PORT="${MIMIC_E2E_CONTROL_PORT:-18787}"
MOCK_PORT="${MIMIC_E2E_MOCK_PORT:-18080}"
python3 - "$CONTROL_PORT" "$MOCK_PORT" <<'PY'
import sys
ports = sys.argv[1:]
if any(not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535 for port in ports):
    raise SystemExit('E2E ports must be integers between 1 and 65535.')
if int(ports[0]) == int(ports[1]):
    raise SystemExit('E2E control and mock ports must be different.')
PY

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
export MIMIC_DEFAULTS_SUITE="devxa.Mimic.CLIE2E.${WORK:t}"
TEST_BUNDLE_ID="${MIMIC_DEFAULTS_SUITE}.App"
unset MIMIC_CONTROL_URL

MIMIC_PID=""

owned_pid() {
  python3 - "$WORK/Mimic.app/Contents/MacOS/Mimic" <<'PY'
import os, subprocess, sys
expected = os.path.realpath(sys.argv[1])
listing = subprocess.run(['ps', '-axo', 'pid=,comm='], check=True, capture_output=True, text=True).stdout
for line in listing.splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and os.path.realpath(fields[1]) == expected:
        print(fields[0])
        break
PY
}

cleanup() {
  local rc=$?
  set +e
  # Recover ownership even if the launcher timed out before returning its PID. A stale PID alone
  # cannot authorize a signal; the executable must still be this run's unique app copy.
  local owned="$(owned_pid)"
  if [ -n "$owned" ]; then
    kill "$owned" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if [ -z "$(owned_pid)" ]; then break; fi
      sleep 0.3
    done
  fi
  if [ -n "$(owned_pid)" ]; then
    echo "Test app did not exit; preserving its files at $WORK" >&2
    exit 1
  fi
  defaults delete "$MIMIC_DEFAULTS_SUITE" >/dev/null 2>&1 || true
  defaults delete "$TEST_BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The shipping app is sandboxed and cannot write to WORK. Run an ad-hoc signed copy
# without its entitlements, as the pass-through e2e harness does. Never alter the build.
ditto "$MIMIC_APP_PATH" "$WORK/Mimic.app"
# AppKit writes window preferences through the bundle's standard domain, independently of
# MIMIC_DEFAULTS_SUITE. Give that framework-owned state a disposable identity as well.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_BUNDLE_ID" "$WORK/Mimic.app/Contents/Info.plist"
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
code() { curl --silent --show-error --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' -X "$1" "http://127.0.0.1:$MOCK_PORT$2"; }

echo "== launching Mimic headless =="
start_output="$("$MIMIC_BIN" app start --headless --wait-seconds 60)" || fail "could not start Mimic"
# Stop only the pid reported by this launch; never use `mimic app stop` here.
MIMIC_PID="$(printf '%s\n' "$start_output" | sed -n 's/.*(pid \([0-9][0-9]*\).*/\1/p')"
if [ -z "$MIMIC_PID" ]; then
  fail "no pid in: $start_output
Something is already answering on control port $CONTROL_PORT. Stop it, or set MIMIC_E2E_CONTROL_PORT."
fi
[ "$MIMIC_PID" = "$(owned_pid)" ] || fail "the reported PID is not this run's app copy"
echo "  ok   reachable (pid $MIMIC_PID)"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$MIMIC_CONTROL_FILE" ]; then break; fi
  sleep 0.2
done
if [ ! -f "$MIMIC_CONTROL_FILE" ]; then
  fail "the launched app did not write its discovery file to $MIMIC_CONTROL_FILE"
fi
"$MIMIC_BIN" state > "$WORK/state.json"
python3 - "$MIMIC_PID" "$WORK/state.json" <<'PY'
import json, os, sys
with open(os.environ['MIMIC_CONTROL_FILE']) as source:
    discovery = json.load(source)
with open(sys.argv[2]) as source:
    state = json.load(source)['state']
with open(os.environ['MIMIC_DATABASE_PATH'], 'rb') as source:
    if source.read(16) != b'SQLite format 3\0':
        raise SystemExit('The requested temporary SQLite database was not created; refusing mutations.')
if not (discovery['pid'] == state['pid'] == int(sys.argv[1])
        and discovery['port'] == int(os.environ['MIMIC_CONTROL_PORT'])
        and discovery['token'] == os.environ['MIMIC_CONTROL_TOKEN']
        and not state.get('storeFailure')):
    raise SystemExit('The isolated on-disk fixture was not confirmed; refusing mutations.')
PY

echo "== scripting the journey from the product goal =="
"$MIMIC_BIN" project create "CLI e2e" --port "$MOCK_PORT" >/dev/null || fail "project create"
PROJECT_READY=0
for _ in {1..50}; do
  "$MIMIC_BIN" state > "$WORK/state.json"
  if python3 - "$WORK/state.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    project = json.load(source)['state'].get('project') or {}
sys.exit(0 if project.get('name') == 'CLI e2e' else 1)
PY
  then PROJECT_READY=1; break; fi
  sleep 0.1
done
[ "$PROJECT_READY" = 1 ] || fail "created project did not become active"
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
