# Hearth — Usage Rules

Hearth turns an OpenAPI 3.x spec into a complete three-layer Req
HTTP client: a raw client, a behaviour, and a Req implementation,
plus Mox plumbing, a `Req.Test` auth test, an external integration
test, and idempotent config patches. The generator is opinionated —
follow the conventions below and the generated code stays clean.

## Setup

Add to `mix.exs`:

    {:hearth, "~> 0.0", only: [:dev, :test], runtime: false}

`mix hearth.gen` auto-runs `mix hearth.install` on a fresh project
(formatter import + `:hearth_domains` config). On an already-installed
project the install step is silent.

## Generate an integration

    mix hearth.gen <source> --integration <Name>

`<source>` is one of:

* a local file path: `priv/specs/stripe.yaml`
* a URL: `https://example.com/openapi.json` (HTTP fetcher coming soon)
* a curated registry shortcut: `stripe`, optionally pinned (`stripe@latest`)

`<Name>` is the integration's module name. It becomes:

    <App>.Integrations.<Name>             # Layer 1 (raw Req client)
    <App>.Integrations.<Name>.<Name>Api   # Layer 2 (behaviour + dispatcher)
    <App>.Integrations.<Name>.<Name>Api.Req
                                          # Layer 3 (Req implementation)
    <App>.Integrations.<Name>.<Name>Api.Mock
                                          # Mox mock for tests

Other flags worth knowing:

* `--domain Billing` — replace the `Integrations` namespace segment
  (`<App>.Billing.<Name>`).
* `--no-domain` — drop the namespace segment entirely
  (`<App>.<Name>`).
* `--tag "<Tag>"` (repeatable) — restrict to a tag, optionally with
  a comma-separated operationId list (`--tag "Customers:create,list"`).
* `--n-operations <N>` — raise the default 25-op gate when
  generating a tag-less subset of a large spec.

`gen` writes five code files (Layer 1/2/3 + auth test + external
test scaffold), the pruned spec at `priv/hearth/<int>.yaml`, the
Mox `defmock`, and idempotent config patches.

## `gen` is create-only

`mix hearth.gen` halts if **any** of the integration's generated
files already exist. **Do not re-run `gen` to update an
integration** — use `mix hearth.regen` instead. To start over,
delete every file under `lib/<app>/integrations/<int>*`,
`test/<app>/integrations/<int>*`, and `priv/hearth/<int>.yaml`,
then re-run `gen`.

## Update an integration with `regen`

    mix hearth.regen <App>.Integrations.<Name>

`regen` reads `priv/hearth/<int>.yaml` (the pruned spec — the
versioned source of truth) and re-renders the three layers plus the
auth test. It does **not** re-run config patches or rewrite the
pruned spec.

To pull in upstream spec changes, edit `priv/hearth/<int>.yaml` and
re-run `regen`.

## Ownership tokens

Hand-edited a generated file? Mark it in the moduledoc:

    @moduledoc """
    Raw Req client for Stripe.

    hearth:owned
    """

* `hearth:owned` — `regen` skips the file entirely.
* `hearth:collaborating` — `regen` prompts y/N before overwriting.
* _(no token)_ — `regen` overwrites silently. The default for
  freshly-generated files.

`:owned` is the common case for Layer 1 (custom auth flows, request
steps, retry policies).

## Calling the integration

Business logic always calls **Layer 2** — the behaviour module:

    StripeApi.list_customers(limit: 10)
    StripeApi.get_customer("cus_123")

Never call Layer 1 (the raw client) or Layer 3 (the Req impl)
directly from business code — go through Layer 2 so tests can stub
it.

## Testing

The Mox mock is pre-wired:

    # config/test.exs (set by `gen`)
    config :my_app, MyApp.Integrations.Stripe.StripeApi,
      impl: MyApp.Integrations.Stripe.StripeApi.Mock

In a test:

    expect(StripeApi.Mock, :list_customers, fn _opts ->
      {:ok, %Req.Response{status: 200, body: %{"data" => []}}}
    end)

The generated external test is `:external`-tagged and excluded by
default. Run live calls with:

    mix test --include external

## The registry — `:hearth_domains`

`hearth.install` initializes `config :<app>, hearth_domains, []`.
Each `gen` appends the new Layer 2 module. Set the value to `false`
to opt out of tracking.

## Common pitfalls

* **Don't re-run `gen` to update** — it halts. Use `regen`.
* **Don't call Layer 1 or Layer 3 from business logic** — go
  through the Layer 2 behaviour so tests can stub it via the Mox
  mock.
* **Hand-edited a generated file? Add `hearth:owned`** before the
  next `regen`, or your changes will be overwritten.
* **Edit `priv/hearth/<int>.yaml` to pull spec changes** — not the
  upstream spec path you originally passed to `gen`.
* **Set the credential** — for an authenticated spec, `gen` wires
  `config/runtime.exs` to read `<INTEGRATION>_API_KEY` from the
  environment. Set it before calling the integration.
