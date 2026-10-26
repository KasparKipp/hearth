# Hearth

**Generate small, Req-based API clients from API specs.**

## What is Hearth?

Hearth is a set of [Igniter](https://hexdocs.pm/igniter) Mix tasks that turn
an OpenAPI 3 or Swagger 2.0 spec into a
**small development kit**. Plain Elixir files you own, built on
[Req](https://hexdocs.pm/req), covering only the operations you pick.
The idea of small, Req-based kits comes from
[Dashbit's "SDKs with Req"](https://dashbit.co/blog/sdks-with-req-stripe).

```bash
mix hearth.gen https://petstore.swagger.io/v2/swagger.json --integration Petstore \
  --tag "pet:get_pet_by_id,find_pets_by_status"
```

You get:

- **A three-layer client**: a raw Req client, a behaviour, its Req implementation.
- **Tests from day one**: a Mox mock, a `Req.Test` auth test, a live-API scaffold.
- **Config wiring**: credentials, test config and servers, patched without regexes.
- **A pruned spec**: just your operations, committed next to the code.

And when the vendor ships a new version:

```bash
mix hearth.diff petstore          # what changed, breaking or not (CI-friendly)
mix hearth.regen petstore --sync  # apply it, renaming the calls to renamed functions
```

Specs are rarely perfect, so `.hearth.exs` lets you fix them without
forking: retag operations, rename them, patch the document, choose the
auth scheme, add headers, merge several specs into one kit. No runtime
macros: everything Hearth writes is code you can read, grep and review.

## What gets generated

```elixir
alias MyApp.Integrations.Petstore.PetstoreApi

# Business logic calls the behaviour…
{:ok, %Req.Response{body: pets}} = PetstoreApi.find_pets_by_status(params: [status: "available"])
{:ok, %Req.Response{body: pet}} = PetstoreApi.get_pet_by_id(42)

# …and tests stub it with the generated Mox mock.
expect(PetstoreApi.Mock, :get_pet_by_id, fn 42, _opts -> {:ok, %Req.Response{status: 200}} end)
```

| Generated                         | What it is                                                  |
| --------------------------------- | ----------------------------------------------------------- |
| `MyApp.Integrations.Petstore`     | Layer 1 — raw Req client: base URL, auth, `request/2`       |
| `….Petstore.PetstoreApi`          | Layer 2 — behaviour + dispatcher; what your code calls      |
| `….PetstoreApi.Req`               | Layer 3 — Req implementation, one function per operation    |
| `….PetstoreApi.Mock`              | Mox mock, wired in `config/test.exs`                        |
| `PetstoreTest`, `PetstoreExternalTest` | `Req.Test` auth test; opt-in `:external` live-API tests |
| `priv/hearth/petstore.yaml`       | the spec pruned to your operations — regen's source of truth |
| `.hearth.exs`                     | one entry per integration: module, source, overrides, and the tags and operations selected |

## Installation

### Using Igniter (Recommended)

```bash
mix igniter.install hearth --only dev,test
```

### Manual Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:hearth, "~> 0.1", only: [:dev, :test], runtime: false},
    {:igniter, "~> 0.5", only: [:dev, :test]}
  ]
end
```

Then run:

```bash
mix deps.get
mix hearth.install  # formatter import
```

## Usage

```bash
# Generate — create-only; halts if the integration already exists
mix hearth.gen priv/specs/acme.yaml --integration Acme

# From a URL, or a registry shortcut (Hearth's, or your own in .hearth.exs)
mix hearth.gen https://acme.example.com/openapi.json --integration Acme
mix hearth.gen acme@1.0     # a shortcut names the integration itself

# Big spec? List its tags and pick a subset
mix hearth.gen priv/specs/acme.yaml --list
mix hearth.gen priv/specs/acme.yaml --integration Acme --tag "Customers:create_customer,list_customers"

# Several specs of one API (modules behind one host)? Merge them into one kit:
# list them in .hearth.exs first, then generate without a source
#   acme: [sources: [items: "priv/specs/acme-items.json", orders: "priv/specs/acme-orders.json"]]
mix hearth.gen --integration Acme --tag "Items:get_item" --tag "Orders:get_order"

# Pick the namespace (default: MyApp.Integrations.Acme)
mix hearth.gen priv/specs/acme.yaml --integration Acme --domain Billing

# Regenerate from the pruned spec (or --all)
mix hearth.regen acme

# Changed `tags:` in .hearth.exs, or pointed `source:` at a newer spec? Re-prune
mix hearth.regen acme --sync

# CI: has the spec drifted from what's generated? Exits non-zero if so
mix hearth.diff acme
mix hearth.diff acme --source priv/specs/acme-2.0.yaml   # preview a new version
```

Stripe's spec tags nothing, so its operations get tags in `.hearth.exs`
before `--tag` can pick them — the [Stripe example](https://github.com/KasparKipp/hearth/tree/main/examples/stripe_demo)
walks through it.

Hand-edited a generated file? Put `hearth:owned` in its `@moduledoc` and
`regen` skips it; `hearth:collaborating` makes `regen` ask first.

Run `mix help hearth.gen` for every option. [`usage-rules.md`](usage-rules.md)
is the full guide — and what a coding agent working in your project should read.

## Status

Early (`0.1.x`). Generation works from OpenAPI 3.0 / 3.1 and Swagger 2.0
specs — local files (YAML or JSON), URLs, and registry shortcuts, Hearth's
(`mix hearth.gen stripe@latest`) or your own in `.hearth.exs`. Bearer,
API-key and HTTP basic auth are wired automatically; OAuth2 and OpenID
Connect leave a TODO in the raw client.

## License

MIT — see [LICENSE](LICENSE).
