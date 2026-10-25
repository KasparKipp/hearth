# Stripe demo

A plain `mix new` app that gets a Stripe client from Hearth: generated
from Stripe's published OpenAPI spec, narrowed to the operations it
uses, and kept in step with Stripe's releases.

Hearth comes in as a path dependency (`../..`), so this tracks the
library in this repo.

## Run it

```bash
mix deps.get
```

### 1. Tag the operations you want

Stripe's spec has 587 operations and none of them carry a tag, so
there's nothing for `--tag` to select. `.hearth.exs` already holds an
`overrides:` stub that tags a few:

```elixir
stripe: [
  overrides: [
    tags: [
      Customers: ["get /v1/customers", "post /v1/customers", "get /v1/customers/{customer}"],
      Subscriptions: ["/v1/subscriptions*"]
    ]
  ]
]
```

An entry is a path glob (`*` matches anything, `/` included), a method
plus a path, or an operationId.

### 2. Generate

```bash
mix hearth.gen stripe@2026-04-22.dahlia --tag Customers --yes
```

This fetches the pinned spec from Stripe's GitHub repo (about 7 MB of
YAML, a few seconds) and writes:

- `lib/stripe_demo/integrations/stripe.ex` — the raw Req client
  (base URL `https://api.stripe.com/v1`).
- `…/stripe/stripe_api.ex` — the behaviour your code calls:
  `get_customers/1`, `post_customers/1`, `get_customers_customer/2`.
- `…/stripe/stripe_api/req.ex` — the Req implementation.
- `test/stripe_demo/integrations/stripe_test.exs` and
  `stripe_external_test.exs`, the Mox mock in `test/support/mocks.ex`,
  and config in `config/`.
- `priv/hearth/stripe.yaml` — the spec pruned to those operations.
- The rest of the `.hearth.exs` entry: module, source, checksum, base
  path, and which tags were selected.

### 3. Test

```bash
mix test                      # Req.Test-backed, no network
mix test --include external   # calls the real API
```

### 4. Keep up with Stripe

```bash
mix hearth.diff stripe --source stripe@latest   # what changed upstream?
```

`diff` writes nothing and exits non-zero on drift, so it can run in CI.
To move to a newer release, point `source:` in `.hearth.exs` at it
and re-prune:

```bash
mix hearth.regen stripe --sync
```

To pick up more operations, add patterns to the overrides, or tags to
`tags:`, and run `--sync` again.

## Known gap: auth

Stripe's spec lists HTTP basic auth first (the secret key as the
username) and bearer second. Hearth wires bearer and API-key auth but
not basic, and picks the first scheme, so the raw client is generated
without auth and with a `TODO`. Choosing `bearerAuth` is on the way.
Until then, pass the key yourself:

```elixir
StripeDemo.Integrations.Stripe.StripeApi.get_customers(auth: {:bearer, "sk_test_…"})
```
