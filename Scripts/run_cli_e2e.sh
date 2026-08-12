#!/bin/zsh
# End-to-end check that the CLI can drive a complete journey without touching the UI.
#
# Launches Mimic headless against a throwaway store, scripts the canonical journey from the product
# goal, and asserts that the same route answers 500 then 200 depending on where the request falls.
# Exercises the seams a unit test cannot: process launch, discovery, HTTP, and real sockets.
#
# Everything this run touches is meant to be disposable, and two of those things were not. Both are
# the rule AGENTS.md draws around the UI suite's database — *a convenience must never be able to
# compute its own target*:
#
#   - **It stops the instance it launched, by pid.** The trap used to call `mimic app stop`, which
#     ignores MIMIC_CONTROL_URL and MIMIC_CONTROL_PORT entirely: `AppCommand.Stop` calls
#     `ControlEndpointFileReader.discover()`, which reads the one `control.json` under Application
#     Support and SIGTERMs whatever pid it names. So on a machine with Mimic open, running this
#     script quit the developer's own instance — and it ran on *every* exit, including the early ones
#     where this script had launched nothing at all. The pid now comes from what `mimic app start`
#     printed about the process it just launched, so the trap can only reach this run's own child.
#   - **It writes its discovery file inside $WORK.** `MIMIC_CONTROL_FILE` is read by
#     `ControlEndpointFile.writeURL`, so the instance advertises itself there instead of at the
#     shared Application Support path, and by `searchURLs`, which the override *replaces* rather
#     than joins — so nothing in this run can fall through to a developer's real instance either.
#     The check after launch is there because that isolation is the one thing here the script cannot
#     arrange by itself: the app is what honours the variable, and if the file is missing afterwards
#     the instance wrote where it always did.
#
# `set -e` was missing too. Every command that can fail is written `… || fail` today, so nothing in
# the current body depends on it — it is here so the next line added without that suffix cannot pass
# silently, which is exactly how a launch failure would otherwise reach the HTTP assertions below and
# report them against an instance that was never running.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
CONTROL_PORT="${MIMIC_E2E_CONTROL_PORT:-18787}"
MOCK_PORT="${MIMIC_E2E_MOCK_PORT:-18080}"

export MIMIC_DATABASE_PATH="$WORK/mimic.sqlite"
export MIMIC_CONTROL_PORT="$CONTROL_PORT"
export MIMIC_CONTROL_URL="http://127.0.0.1:$CONTROL_PORT"
export MIMIC_CONTROL_FILE="$WORK/control.json"
# The credential has to be supplied, not discovered, and moving the file is what makes that true.
#
# `MIMIC_CONTROL_FILE` is honoured by the *app* — `ControlEndpointFile` in ControlPlane — and not by
# the CLI, which carries its own reader searching only the two Application Support paths
# (`grep -n MIMIC_CONTROL_FILE Sources/MimicCLICore/*.swift` returns nothing; mirroring it is an open
# item in AGENTS.md). So the instance advertises itself in $WORK and `mimic` cannot see that file.
# `MIMIC_CONTROL_URL` and `MIMIC_CONTROL_PORT` do not close the gap: they resolve the *destination*,
# and `resolveToken` never consults them. Every command would reach the right port with no token and
# come back 401 — `ControlServer.denial` guards every route — while `mimic app start` still looked
# fine, because `isReachable` accepts a 401 as proof something answered.
#
# Both sides read `MIMIC_CONTROL_TOKEN` first: `ControlServer.init` for the token it demands,
# `ControlEndpointFileReader.resolveToken` for the one it sends. Setting it here is what makes an
# isolated run work at all, and it is a fresh value per run rather than a fixed string so a leftover
# file from a previous run cannot authenticate against this one.
export MIMIC_CONTROL_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# Prefer a freshly built CLI; fall back to one on PATH.
#
# `|| true` because of `pipefail`, not because a failure here is acceptable: `head -1` closes the pipe
# as soon as it has a line, so a `find` with several matches is killed by SIGPIPE and the pipeline
# reports 141. The empty-result case is handled immediately below, which is the check that matters.
MIMIC_BIN="$(find "$ROOT_DIR" -type f -name mimic -perm -u+x -path '*Build/Products*' 2>/dev/null | head -1 || true)"
if [ -z "$MIMIC_BIN" ]; then
  MIMIC_BIN="$(command -v mimic)" || {
    echo "Could not find the mimic binary. Build it with:" >&2
    echo "  xcodebuild -workspace Mimic.xcworkspace -scheme Mimic -configuration Debug build" >&2
    exit 1
  }
fi

# Set the moment `mimic app start` reports a pid, and read by nothing else. Declared before the trap
# so `set -u` cannot turn an early exit into an unbound-variable error inside cleanup.
MIMIC_PID=""

cleanup() {
  local rc=$?
  # Nothing in here may abort the trap: a cleanup that stops halfway leaves a headless Mimic running
  # and a temporary directory behind, and it would do it while reporting whatever status it failed
  # with rather than the one the run actually earned.
  set +e
  if [ -n "$MIMIC_PID" ] && kill -0 "$MIMIC_PID" 2>/dev/null; then
    # SIGTERM rather than SIGKILL, and then wait: the app ignores the default disposition and runs a
    # handler that removes its discovery file and exits, so killing harder would leave the file
    # behind — the stale-endpoint case `ControlEndpointFile.discover` then has to skip.
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
# `AppCommand.Start` prints "Started Mimic (pid 1234, headless) at http://…" for the process it
# launched. That number is the only handle this script has on its own instance — the discovery file
# is the app's to write, and reading the pid back out of it would be trusting the same shared-state
# path that made the old cleanup dangerous.
#
# Capturing that line in `$( )` is only safe because `AppLauncher.launch` points the launched app's
# stdout, stderr and stdin at `FileHandle.nullDevice`. A command substitution waits for the write end
# of its pipe to close everywhere, not for the command to exit, so a launcher that let the app
# inherit those descriptors would hang this line for as long as Mimic stayed up.
MIMIC_PID="$(printf '%s\n' "$start_output" | sed -n 's/.*(pid \([0-9][0-9]*\).*/\1/p' | head -1)"
if [ -z "$MIMIC_PID" ]; then
  # The other thing `app start` prints is "Mimic is already running at …", with no pid, when the
  # control URL already answers. That is a leftover from an earlier run of this script, and adopting
  # it would mean asserting against somebody else's store.
  fail "no pid in: $start_output
Something is already answering on control port $CONTROL_PORT. Stop it, or set MIMIC_E2E_CONTROL_PORT."
fi
echo "  ok   reachable (pid $MIMIC_PID)"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -f "$MIMIC_CONTROL_FILE" ]; then break; fi
  sleep 0.2
done
[ -f "$MIMIC_CONTROL_FILE" ] || fail "the instance did not write its discovery file to
  $MIMIC_CONTROL_FILE
so it wrote to the shared Application Support path instead, and this run has overwritten the file a
developer's own Mimic advertises itself in. MIMIC_CONTROL_FILE is what redirects it."

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
