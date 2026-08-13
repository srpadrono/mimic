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

**Leading fragment definitions are skipped**, braces counted so nested selections close correctly.
Most real clients emit their fragments ahead of the operation, and the scanner used to stop at the
first `{` it found — the fragment's — and name the document after *its* first field. A body reading
`fragment fields on User { name }` before `query GetUser { … }` therefore resolved to the operation
`name`, so a mock declared for `GetUser` did not match and a well-formed request 404'd. A fragment
whose braces never close still yields "not GraphQL", which falls back to path routing rather than
matching on a name guessed out of a broken document.

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

The window splits GraphQL traffic in a HAR by operation, so a capture of twenty distinct calls
imports as twenty addressable mocks instead of twenty entries that all look like `POST /graphql` and
fight over one route. Each is named after its operation and grouped under `GraphQL`.

**Only the window**, and this line used to say "`mimic` and the UI both". It cannot: the splitting
lives in `SpecImport.HARParser`, and `SpecImport` is linked by `AppFeatures` and the app target
alone — no edge reaches it from `MimicCLICore` or `ControlPlane` in either manifest, which is the
same missing edge behind there being no `mimic import` at all. A script reads the HAR itself and
issues `mimic endpoint create --graphql-operation …` per operation.

This line used to publish a `grep` for the reader to run by hand. That is what
[`Scripts/check_module_edges.py`](../Scripts/check_module_edges.py) does now, on every CI run, over
the transitive closure of both manifests rather than the direct edges a grep can see.

Two operations on the same route are not treated as duplicates of one another — the operation is what
makes them distinct.

## Known limits

- **A batch never matches a mock that names an operation.** Some clients POST a JSON *array* of
  operations and expect an array back. No single mocked response can represent that honestly, so
  `GraphQLRequest.operation(inBody:)` answers `nil` for an array of more than one, and every
  endpoint declaring `graphqlOperation` is then a non-match — not a weak one. A mock for
  `SendPayment` will not answer a batch that contains `SendPayment`.

  **A catch-all still answers it**, and this bullet used to say the opposite — "such a request
  matches nothing and is reported as unmatched". A bare `POST /graphql` declares no operation, which
  `RequestMatcher.operationSpecificity` scores as a match at the lowest specificity, exactly as the
  precedence section above promises. So the catch-all's status and body are what the client gets,
  and the array it expected is what it does not get.

  **Nothing reports the batch as a batch.** With no catch-all the request falls to the same
  `404` and the same `.unmatched` outcome in the request log that a typo'd path produces; there is
  no distinct outcome, message or flag saying a batch arrived. `GraphQLRequest.isBatched` is the
  predicate that would tell those two apart and nothing in `Sources` calls it — telling the client
  means a new `ResolvedResponse`, the way `journeyBlocked` already carries its own reason, which is
  a change in `RequestMatcher` rather than in the scanner.
- **Persisted queries** that send only a hash carry no document to read, so there is nothing to
  match on. Mock them by hash on the path, or turn persisted queries off in your test build.
- **`GET`-style GraphQL** (`?query=…`) is not parsed; the discriminator is read from the request body.
