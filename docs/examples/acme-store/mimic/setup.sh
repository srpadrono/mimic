#!/bin/bash
# Builds the "Acme Store" Mimic project from the CLI: three named servers, each forwarding to the
# real Acme service behind it and keeping every reply it forwards as a mock.
#
#   Auth      Mimic 8080  ->  real 9080
#   Catalog   Mimic 8081  ->  real 9081
#   Payments  Mimic 8082  ->  real 9082
#
#   mimic/setup.sh            # create the project, or reuse it
#   mimic/setup.sh --fresh    # delete it first, for a clean recording
#
# Start the stand-in backend first: `python3 backend/acme_backend.py`.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REAL_BASE="${ACME_REAL_BASE:-9080}"
MOCK_BASE="${ACME_MOCK_BASE:-8080}"

mimic app start --wait-seconds 60 >/dev/null

exists=$(mimic project list | json_get "any(p['name'] == '$PROJECT_NAME' for p in d.get('projects') or [])")
if [ "${1:-}" = "--fresh" ] && [ "$exists" = "True" ]; then
  mimic project delete "$PROJECT_NAME" >/dev/null
  exists=False
fi
if [ "$exists" = "True" ]; then
  mimic project open "$PROJECT_NAME" >/dev/null
else
  mimic project create "$PROJECT_NAME" --port "$MOCK_BASE" >/dev/null
fi

# Create and open settle asynchronously: wait until the project is the open one.
for _ in $(seq 1 100); do
  [ "$(mimic state | json_get "(d['state'].get('project') or {}).get('name')")" = "$PROJECT_NAME" ] && break
  sleep 0.1
done
[ "$(mimic state | json_get "(d['state'].get('project') or {}).get('name')")" = "$PROJECT_NAME" ] \
  || die "$PROJECT_NAME did not open"

mimic server configure --name Auth --upstream "http://127.0.0.1:$REAL_BASE" \
  --pass-through true --capture-responses true >/dev/null
for offset in 1 2; do
  name=$( [ "$offset" = 1 ] && echo Catalog || echo Payments )
  port=$((MOCK_BASE + offset))
  upstream="http://127.0.0.1:$((REAL_BASE + offset))"
  id=$(backend_id "$name")
  if [ -z "$id" ]; then
    mimic server backend add --name "$name" --port "$port" --upstream "$upstream" \
      --pass-through true --capture-responses true >/dev/null
  else
    mimic server backend update "$id" --port "$port" --upstream "$upstream" \
      --pass-through true --capture-responses true >/dev/null
  fi
done

mimic server stop >/dev/null 2>&1 || true
mimic server start >/dev/null
for offset in 0 1 2; do wait_for_port $((MOCK_BASE + offset)); done

echo "Acme Store is serving: Auth :$MOCK_BASE, Catalog :$((MOCK_BASE + 1)), Payments :$((MOCK_BASE + 2))."
echo "Pass-through and capture are on. Run the app once to record the real responses."
