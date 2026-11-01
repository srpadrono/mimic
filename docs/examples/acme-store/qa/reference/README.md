# Answer key: Checkout scenarios

`scenarios.sh` creates these as journeys in the `Checkout QA` group. Run each with
`../../mimic/run.sh "<name>"`; the happy path is `--none`.

| # | Journey | Steps | Expected |
| --- | --- | --- | --- |
| 1 | (none) | recorded responses only | Paid. One `POST /orders`. |
| 2 | Checkout: card declined, then another card | `POST /orders` 402, then 201 | Declined banner, card switched, paid. Two `POST /orders`. |
| 3 | Checkout: payments busy, then paid | `POST /orders` 503 ×2 with `Retry-After: 1`, then 201 | "Retrying (2 of 3)", "Retrying (3 of 3)", paid. Three `POST /orders`. |
| 4 | Checkout: session expires at payment | `POST /orders` 401, `POST /auth/refresh` 200, `POST /orders` 201 | "Session refreshed", paid. |
| 5 | Checkout: item sells out in the cart | `POST /orders` 409 out_of_stock (Monstera), then 201 | Monstera removed with a message, rest paid. |
| 6 | Checkout: slow catalog | `GET /products` 200 after 2.5 s | Loading grid for 2.5 s, then paid. |
| 7 | Checkout: catalog offline, then back | `GET /products` held until the app times out, then 200 | Offline view, Retry, paid. |
| 8 | Checkout: session expires while browsing | `GET /products` 401 token_expired, `POST /auth/refresh` 200, `GET /products` 200 | Products load after a silent refresh, paid. |

On the app as shipped, two of these fail.

**Scenario 3, the planted bug.** It fails because the app gives up after two attempts ("Payments is
unavailable"), the journey's third step is never served, and the log shows two `POST /orders`
instead of three. The fix is one line in `Store.checkout()`:

```diff
-                if attempt < maxPaymentAttempts - 1 {
+                if attempt < maxPaymentAttempts {
```

**Scenario 8, the bug nobody planted.** The spec says a `401 token_expired` from *any* service
means refresh and retry once, but only `checkout()` does that. `Store.loadCatalog()` treats the
401 like any other failure and shows "Your session has expired." in place of the grid; the log
shows no `POST /auth/refresh`. We left it in on purpose after an agent found it in the first dry
run. The fix gives `loadCatalog()` the same refresh-then-retry-once rule `checkout()` already
follows, and signs the customer out when the refresh itself answers 401.
