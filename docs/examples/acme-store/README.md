# Acme Store: close the loop with a coding agent

Acme Store is a small Mac shop app that talks to three backends: **Auth**, **Catalog** and
**Payments**. It exists to show one workflow: a coding agent records a real checkout with Mimic,
works out every way the backends can answer, scripts each one as a journey, runs the app through
all of them, and fixes the app when it gets one wrong.

```text
 Acme Store ──► Mimic :8080 Auth ─────► real :9080
            ──► Mimic :8081 Catalog ──► real :9081
            ──► Mimic :8082 Payments ─► real :9082
```

| Path | What it is |
| --- | --- |
| `Sources/AcmeStore` | The app. SwiftUI, macOS 14 or later. A network strip along the bottom shows each call, its backend and its status. |
| `backend/acme_backend.py` | The stand-in "real" API. It only ever succeeds. |
| `openapi.yaml` | The contract for all three services, including the errors the real API never shows on a good day. |
| `mimic/setup.sh` | Builds the `Acme Store` Mimic project: three named servers with pass-through and capture on. |
| `mimic/run.sh` | Runs one scenario: rewinds Mimic, plays the app through a checkout, prints what happened. |
| `qa/QA_PROMPT.md` | The prompt for the agent. |
| `qa/reference/` | The answer key: the scenarios the agent should arrive at. |

The app ships with a bug in its first version, left in on purpose so the loop has something to
catch. The spec asks for three attempts when Payments is busy.

## Run it

You need Mimic (with the `mimic` command on your `PATH`), Xcode or the Swift toolchain, and
`python3`. Everything below runs from this folder.

```bash
# 1. The real backend, in its own terminal.
python3 backend/acme_backend.py

# 2. The Mimic project: three servers in front of it, recording.
mimic/setup.sh --fresh

# 3. Record one real checkout. The app signs in, adds two products and pays.
mimic/run.sh --none
```

Mimic now holds a mock for every call on the happy path, on the backend it came from. Stop the
real backend: from here on Mimic answers everything.

```bash
# 4. Hand the checkout to your agent.
claude "$(cat qa/QA_PROMPT.md)"
```

To skip the agent and use the answer key instead:

```bash
qa/reference/scenarios.sh
mimic/run.sh "Checkout: payments busy, then paid"
```

## Run the app by hand

```bash
swift run AcmeStore                 # click through it yourself
swift run AcmeStore --autoplay      # sign in, add two products, pay; prints ACME_RESULT {json}
```

`ACME_AUTH_URL`, `ACME_CATALOG_URL` and `ACME_PAYMENTS_URL` point the app somewhere else, for
example straight at the real backend on 9080 to 9082.
