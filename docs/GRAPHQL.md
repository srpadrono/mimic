# GraphQL

GraphQL routes every operation through a single path — almost always `POST /graphql` — so method and
path cannot tell two calls apart. Mimic discriminates on the **operation** instead.

```bash
mimic endpoint create POST /graphql --graphql-operation GetAccountSummary \
  --status 200 --body '{"data":{"accountSummary":{"balance":1520}}}'

mimic endpoint create POST /graphql --graphql-operation SendPayment \
  --status 201 --body '{"data":{"pay":{"id":"p1"}}}'

# No operation named: the catch-all for everything you have not mocked yet.
mimic endpoint create POST /graphql \
  --status 500 --body '{"errors":[{"message":"unmocked operation"}]}'
```

## How the operation is identified

`operationName` is the obvious discriminator, but it is **optional** and plenty of clients omit it.
So Mimic falls back the way a person would:

1. the `operationName` the client sent
2. otherwise the name written in the document — `query GetAccountSummary { … }`
3. otherwise the **first root field** — `{ accountSummary { balance } }` → `accountSummary`

That third step is what makes two anonymous queries distinguishable. An alias resolves to the field
it aliases (`{ latest: inbox { … } }` matches `inbox`), because the field is the stable half of that
pair — the alias is whatever the caller felt like typing.

Comments are ignored, so a `# query Decoy { }` cannot masquerade as an operation, and variable
definitions (`query GetUser($id: ID!)`) do not swallow the name.

This is a tolerant scanner, not a GraphQL parser: it identifies operations in real traffic rather
than validating a schema. A body it cannot read is simply "not GraphQL", and routing falls back to
method and path as before.

## Precedence

A mock naming an operation **beats** one that does not, regardless of declaration order, so a bare
`POST /graphql` keeps working as a catch-all underneath your named mocks.

A mock naming an operation answers **only** that operation. It never answers a different one — if
nothing else matches, the request is reported as [unmatched](CLI.md#request-log) rather than being
quietly handled by the wrong mock.

## Journeys

Journey steps take the same discriminator, which is what makes a GraphQL flow scriptable at all —
every step is otherwise the identical `POST /graphql`:

```bash
mimic journey create "Retry after failure"
mimic journey step add "Retry after failure" POST /graphql --graphql-operation SignIn            --status 200
mimic journey step add "Retry after failure" POST /graphql --graphql-operation GetAccountSummary --status 500
mimic journey step add "Retry after failure" POST /graphql --graphql-operation GetInbox          --status 200
mimic journey step add "Retry after failure" POST /graphql --graphql-operation GetAccountSummary --status 200
mimic journey activate "Retry after failure"
```

The same account query fails and then succeeds, exactly as in the REST version — see
[JOURNEYS.md](JOURNEYS.md).

## Importing a capture

`mimic` and the UI both split GraphQL traffic in a HAR by operation, so a capture of twenty distinct
calls imports as twenty addressable mocks instead of twenty entries that all look like
`POST /graphql` and fight over one route. Each is named after its operation and grouped under
`GraphQL`.

Two operations on the same route are not treated as duplicates of one another — the operation is what
makes them distinct.

## Known limits

- **Batched requests are not matched.** Some clients POST a JSON *array* of operations and expect an
  array back. No single mocked response can represent that honestly, so such a request matches
  nothing and is reported as unmatched rather than silently answered with one of the operations.
- **Persisted queries** that send only a hash carry no document to read, so there is nothing to
  match on. Mock them by hash on the path, or turn persisted queries off in your test build.
- **`GET`-style GraphQL** (`?query=…`) is not parsed; the discriminator is read from the request body.
