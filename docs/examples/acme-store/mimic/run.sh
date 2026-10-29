#!/bin/bash
# Runs one scenario end to end and prints what happened.
#
#   mimic/run.sh "Checkout: payments busy, then paid"   # activate that journey, then play the app
#   mimic/run.sh --none                                 # no journey: the recorded responses only
#
# It rewinds Mimic (`reset --scope all` clears the log and restarts the journey), launches Acme Store
# with --autoplay so it signs in, adds two products and pays, then prints:
#
#   1. the app's own account of the run (ACME_RESULT: outcome, banners, requests),
#   2. the journey's progress (which steps were served),
#   3. Mimic's request log for the run.
#
# Pass or fail is for the caller to decide against what the scenario expects.
# ACME_APP overrides the app binary; by default it is built here in release mode.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: $0 \"<journey name>\" | --none"
APP="${ACME_APP:-$EXAMPLE_DIR/.build/release/AcmeStore}"
if [ -z "${ACME_APP:-}" ] && [ ! -x "$APP" ]; then
  swift build -c release --package-path "$EXAMPLE_DIR" >&2
fi

pkill -x AcmeStore 2>/dev/null || true
mimic reset --scope all >/dev/null
if [ "$1" = "--none" ]; then
  mimic journey deactivate >/dev/null 2>&1 || true
else
  mimic journey activate "$1" >/dev/null
fi

output=$(mktemp)
"$APP" --autoplay --quit-after "${ACME_LINGER:-3}" >"$output" 2>&1 &
app=$!
for _ in $(seq 1 600); do
  grep -q '^ACME_RESULT ' "$output" && break
  kill -0 "$app" 2>/dev/null || break
  sleep 0.1
done
wait "$app" 2>/dev/null || true

echo "== app =="
grep '^ACME_RESULT ' "$output" | sed 's/^ACME_RESULT //' | python3 -m json.tool || {
  echo "Acme Store did not report a result. Its output:"; cat "$output"
}
rm -f "$output"

if [ "$1" != "--none" ]; then
  echo "== journey =="
  mimic journey status | python3 -c '
import json, sys
status = json.load(sys.stdin).get("journeyStatus") or {}
print("%s: %s of %s steps served, complete: %s" % (
    status.get("journeyName"), sum(1 for s in status.get("steps") or [] if s.get("isExhausted")),
    status.get("totalSteps"), status.get("isComplete")))
for step in status.get("steps") or []:
    answer = step.get("statusCode") or step.get("failure")
    print("  %d. %s %s -> %s  served %d of %d" % (
        step["index"] + 1, step["method"], step["path"], answer, step["servedCount"], step["repeatCount"]))
'
fi

echo "== mimic log =="
mimic log list --limit 30 --format text
