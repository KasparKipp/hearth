# Hearth

**Strike sparks from OpenAPI specs into Req HTTP clients.**

Hearth is a set of [Igniter](https://hexdocs.pm/igniter) Mix tasks that turn an
OpenAPI 3.0 / 3.1 spec into a ready-to-use, testable [Req](https://hexdocs.pm/req)
integration in your app — plain Elixir files you own, not a runtime macro.

```bash
mix hearth.gen priv/specs/petstore.yaml --integration Petstore
```

```elixir
# Business logic calls the behaviour…
{:ok, %Req.Response{body: pets}} = PetstoreApi.list_pets(params: [limit: 10])
{:ok, %Req.Response{}} = PetstoreApi.show_pet_by_id("42")

# …and tests stub it with the generated Mox mock.
expect(PetstoreApi.Mock, :list_pets, fn _opts -> {:ok, %Req.Response{status: 200}} end)
```

For each spec Hearth generates three layers, the test plumbing around them,
and idempotent config patches:

| Generated                         | What it is                                                  |
| --------------------------------- | ----------------------------------------------------------- |
| `MyApp.Integrations.Petstore`     | Layer 1 — raw Req client: base URL, auth, `request/2`       |
| `….Petstore.PetstoreApi`          | Layer 2 — behaviour + dispatcher; what your code calls      |
| `….PetstoreApi.Req`               | Layer 3 — Req implementation, one function per operation    |
| `….PetstoreApi.Mock`              | Mox mock, wired in `config/test.exs`                        |
| `PetstoreTest`, `PetstoreExternalTest` | `Req.Test` auth test; opt-in `:external` live-API tests |
| `priv/hearth/petstore.yaml`       | the spec pruned to your operations — regen's source of truth |
| `.hearth.exs`                     | one entry per integration: module, source, base path, and the tags and operations selected |

## Installation

### Using Igniter (Recommended)

```bash
mix igniter.install hearth
```

### Manual Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:hearth, "~> 0.0", only: [:dev, :test], runtime: false},
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
mix hearth.gen priv/specs/stripe.yaml --integration Stripe

# Big spec? List its tags and pick a subset
mix hearth.gen priv/specs/stripe.yaml --list
mix hearth.gen priv/specs/stripe.yaml --integration Stripe --tag "Customers:create,list"

# Pick the namespace (default: MyApp.Integrations.Stripe)
mix hearth.gen priv/specs/stripe.yaml --integration Stripe --domain Billing

# Regenerate from the pruned spec (or --all)
mix hearth.regen stripe

# Changed `tags:` in .hearth.exs, or pointed `source:` at a newer spec? Re-prune
mix hearth.regen stripe --sync
```

Hand-edited a generated file? Put `hearth:owned` in its `@moduledoc` and
`regen` skips it; `hearth:collaborating` makes `regen` ask first.

Run `mix help hearth.gen` for every option. [`usage-rules.md`](usage-rules.md)
is the full guide — and what a coding agent working in your project should read.

## Status

Early (`0.0.x`). Generation works from **local spec files** (YAML or JSON).
URL sources and curated registry shortcuts (`mix hearth.gen stripe`) are
recognized but don't generate yet — that needs the HTTP fetcher. Bearer and
API-key auth are wired automatically; OAuth2, OpenID Connect and HTTP basic
leave a TODO in the raw client.

## License

MIT — see [LICENSE](LICENSE).
