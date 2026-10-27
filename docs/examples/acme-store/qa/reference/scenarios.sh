#!/bin/bash
# The reference answer: the seven Checkout scenarios as Mimic journeys.
#
# An agent doing the QA prompt should arrive at something close to this on its own, from the
# recording, the app code and openapi.yaml. Keep it out of the agent's context; it is here so a
# reader can compare, and so the demo can be rebuilt without an agent.
#
# Run after mimic/setup.sh and one recorded checkout. It stops forwarding, so from here on every
# answer comes from Mimic: a recorded response, or a journey step.
set -euo pipefail
source "$(dirname "$0")/../../mimic/lib.sh"
BODIES="$(dirname "$0")/bodies"

CATALOG=$(backend_id Catalog)
PAYMENTS=$(backend_id Payments)
[ -n "$CATALOG" ] && [ -n "$PAYMENTS" ] || die "run mimic/setup.sh first"

mimic server configure --pass-through false >/dev/null
mimic server backend update "$CATALOG" --pass-through false >/dev/null
mimic server backend update "$PAYMENTS" --pass-through false >/dev/null

journey() { # journey NAME DESCRIPTION
  mimic journey delete "$1" >/dev/null 2>&1 || true
  mimic journey create "$1" --group "$JOURNEY_GROUP" --summary "$2" >/dev/null
}
step() { mimic journey step add "$@" >/dev/null; }

paid='{"orderId":"ORD-2001","status":"paid","total":63.5,"currency":"USD"}'

J="Checkout: card declined, then another card"
journey "$J" "402 card_declined on the first payment; the customer switches card and pays."
step "$J" POST /orders --backend "$PAYMENTS" --status 402 \
  --body '{"error":"card_declined","message":"Your card was declined. Try another card."}'
step "$J" POST /orders --backend "$PAYMENTS" --status 201 --body "$paid"

J="Checkout: payments busy, then paid"
journey "$J" "Payments answers 503 twice with Retry-After: 1. The spec asks for 3 attempts, so the third pays."
step "$J" POST /orders --backend "$PAYMENTS" --status 503 --repeat-count 2 -H 'Retry-After: 1' \
  --body '{"error":"payments_unavailable","message":"Payments is busy."}'
step "$J" POST /orders --backend "$PAYMENTS" --status 201 --body "$paid"

J="Checkout: session expires at payment"
journey "$J" "401 token_expired on payment; the app refreshes the token and retries once."
step "$J" POST /orders --backend "$PAYMENTS" --status 401 \
  --body '{"error":"token_expired","message":"Your session has expired."}'
step "$J" POST /auth/refresh --backend primary --status 200 --body '{"token":"tok_live_refreshed"}'
step "$J" POST /orders --backend "$PAYMENTS" --status 201 --body "$paid"

J="Checkout: item sells out in the cart"
journey "$J" "409 out_of_stock for the Monstera; it leaves the cart and the rest pays."
step "$J" POST /orders --backend "$PAYMENTS" --status 409 \
  --body '{"error":"out_of_stock","message":"Monstera just sold out.","productId":"p_plant"}'
step "$J" POST /orders --backend "$PAYMENTS" --status 201 \
  --body '{"orderId":"ORD-2002","status":"paid","total":39.5,"currency":"USD"}'

J="Checkout: slow catalog"
journey "$J" "The catalog takes 2.5 seconds; the grid shows its loading state, then checkout completes."
step "$J" GET /products --backend "$CATALOG" --status 200 --delay 2500 --body-file "$BODIES/products.json"

J="Checkout: catalog offline, then back"
journey "$J" "The catalog never answers (the app gives up after 4 s); Retry loads it and checkout completes."
step "$J" GET /products --backend "$CATALOG" --fail timeout --hold-ms 6000
step "$J" GET /products --backend "$CATALOG" --status 200 --body-file "$BODIES/products.json"

echo "Created the Checkout QA journeys. Run one with: mimic/run.sh \"Checkout: payments busy, then paid\""
