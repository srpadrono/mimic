# Shared helpers for the Acme Store scripts. Sourced, not run.
#
# MIMIC_BIN picks the CLI (default: `mimic` on PATH). Every helper reads the CLI's JSON output with
# python3, which macOS ships, so nothing else needs installing.

MIMIC_BIN="${MIMIC_BIN:-mimic}"
PROJECT_NAME="${ACME_PROJECT:-Acme Store}"
JOURNEY_GROUP="Checkout QA"
EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mimic() { command "$MIMIC_BIN" "$@"; }

die() { echo "error: $*" >&2; exit 1; }

# json_get EXPR: evaluates a Python expression against the JSON on stdin, bound to `d`.
json_get() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
value = eval(sys.argv[1], {"d": d})
print("" if value is None else value)
' "$1"
}

# backend_id NAME: the UUID of the project's additional backend called NAME.
backend_id() {
  mimic server status | json_get "next((b['id'] for b in (d.get('server') or {}).get('backends') or [] if b['name'] == '$1'), None)"
}

wait_for_port() {
  local port=$1 tries=0
  until nc -z 127.0.0.1 "$port" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 100 ] && die "nothing is listening on $port"
    sleep 0.1
  done
}
