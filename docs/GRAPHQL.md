# GraphQL matching

GraphQL commonly sends every operation to `POST /graphql`. Mimic distinguishes those calls by operation as well as method and path.

```bash
mimic endpoint create POST /graphql --graphql-operation GetAccountSummary \
  --status 200 --body '{"data":{"accountSummary":{"balance":1520}}}'
mimic endpoint create POST /graphql --status 500 \
  --body '{"errors":[{"message":"unmocked operation"}]}'
```

The second endpoint is a catch-all. A named-operation endpoint wins over a bare endpoint regardless of declaration order and never answers a different operation. Journey steps use the same discriminator.

Mimic identifies an operation from the request's `operationName`, then from a named operation in the document, then from its first root field. An alias resolves to the field it names. The scanner skips comments and leading fragments; it is tolerant matching, not schema validation. If it cannot identify GraphQL, normal method-and-path routing applies.

The window's HAR importer splits captured GraphQL calls by operation into reviewable endpoints. Spec parsing is window-only; a script can create named endpoints with `--graphql-operation`.

## Known limits

- A top-level batch array, even with one operation, does not match an operation-specific mock. A bare catch-all can answer it, but cannot construct a separate reply for each batched operation. Without a catch-all, it is logged as unmatched.
- A persisted query that sends only a hash has no document from which to infer an operation. Use a route-based mock or disable persisted queries in the test client.
- `GET` queries in URL parameters are not parsed for operation matching; the discriminator is read from the request body.
