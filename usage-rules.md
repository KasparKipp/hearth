# Hearth — Usage Rules

Hearth turns an OpenAPI 3.x spec into a complete three-layer Req
HTTP client: a raw client, a behaviour, and a Req implementation,
plus Mox plumbing, a `Req.Test` auth test, an external integration
test, and idempotent config patches. The generator is opinionated —
follow the conventions below and the generated code stays clean.

## Setup

With Igniter (recommended):

    mix igniter.install hearth

Or manually — add to `mix.exs`:

    {:hearth, "~> 0.0", only: [:dev, :test], runtime: false},
    {:igniter, "~> 0.5", only: [:dev, :test]}

then run `mix deps.get` and `mix hearth.install` (formatter import).
Hearth's tasks run on Igniter, which Hearth
declares as an optional dependency — without `igniter` in your deps the
tasks only print an install hint.

## Generate an integration

    mix hearth.gen <spec-file> --integration <Name>

Only local spec files generate code today: `priv/specs/stripe.yaml`
(`.yaml`, `.yml`, or `.json`). URL sources and registry shortcuts
(`stripe`, `stripe@latest`) are recognized but do not generate yet —
they need the HTTP fetcher, which is coming soon.

`<Name>` is the integration's module name. With the default domain
it becomes:

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
* `--n-operations <N>` — without `--tag`, a spec with more than 25
  operations halts with a tag listing. Pass the spec's operation
  count to generate everything anyway.
* `mix hearth.gen <spec-file> --list` — print the spec's tags and a
  ready-to-edit `--tag` command, without generating anything.

`gen` writes five code files (Layer 1/2/3 + auth test + external
test scaffold), the pruned spec at `priv/hearth/<int>.yaml`, the
Mox `defmock`, and idempotent config patches. Its output lists every
file it created.

## `gen` is create-only

`mix hearth.gen` halts if **any** of the integration's generated
files already exist. **Do not re-run `gen` to update an
integration** — use `mix hearth.regen` instead. To start over,
delete the generated files `gen` listed (the halt message names the
ones still present) and `priv/hearth/<int>.yaml`, then re-run `gen`.
`gen` replaces the integration's `.hearth.exs` entry.

## Update integrations with `regen`

    mix hearth.regen stripe              # one integration
    mix hearth.regen stripe,send_grid    # several
    mix hearth.regen --all               # every integration in .hearth.exs

Name an integration by the `--integration` it was generated with, not
by its module. With no name and no `--all`, `regen` halts.

`regen` reads `priv/hearth/<int>.yaml` (the pruned spec — the
versioned source of truth) and re-renders the three layers plus the
auth test. If any named integration fails, nothing is written. It does **not** re-run config patches or rewrite the
pruned spec.

To move one integration into a new namespace:

    mix hearth.regen stripe --module MyApp.Payments.Stripe

The module must end in the integration name. `--module` creates the
new modules (halting if any exist), points the `.hearth.exs` entry at
them, and wires their mock and config. The old modules and their config stay
untouched — delete them once callers use the new module.

Add `--remove-old` to remove the old module in the same run — its
files, config entries and `defmock`:

    mix hearth.regen stripe --module MyApp.Payments.Stripe --remove-old

Files you've claimed (an ownership token, or the external test
scaffold) are kept and listed. `--remove-old` without `--module` halts.

To pull in upstream spec changes, edit `priv/hearth/<int>.yaml` and
re-run `regen`.

## `.hearth.exs`

`gen` records each integration in `.hearth.exs` at the project root,
keyed by its snake_case name:

    [
      integrations: [
        stripe: [
          module: MyApp.Integrations.Stripe,
          source: "priv/specs/stripe.yaml",
          base_path: "/v1",
          tags: [
            Customers: [include: ["GetCustomers"], exclude: ["DeleteCustomersCustomer"]],
            Subscriptions: :all,
            Invoices: :none
          ]
        ]
      ]
    ]

* `module` — the Layer 1 module. `regen` derives every other module
  from it and halts without it.
* `source` — the spec `gen` ran on.
* `base_path` — the path prefix `gen` folded into the client's base
  URL. A new path in the pruned spec must sit under it — `regen` halts
  otherwise.
* `tags` — every tag in the source spec and what `gen` selected from
  it: `:all`, `:none`, or `include:` / `exclude:` lists of
  operationIds. Operations without a tag go under `untagged:`.

Commit it alongside `priv/hearth/`. The pruned spec itself is plain
OpenAPI.

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

Only the `@moduledoc` counts — a token in a comment, a `@doc` or a
string is ignored. The generated auth test starts with
`@moduledoc false`; replace it with a string to mark that file.

`:owned` is the common case for Layer 1 (custom auth flows, request
steps, retry policies).

## Calling the integration

Business logic always calls **Layer 2** — the behaviour module:

    StripeApi.list_customers(limit: 10)
    StripeApi.get_customer("cus_123")

Never call Layer 1 (the raw client) or Layer 3 (the Req impl)
directly from business code — go through Layer 2 so tests can stub
it.

## Credentials

For a bearer or API-key spec, the credential comes from the
`:api_key` option, or else from config:

    config :my_app, MyApp.Integrations.Stripe, api_key: "sk_…"
    StripeApi.list_customers(api_key: tenant.stripe_key)

`gen` wires `config/runtime.exs` to read `<INTEGRATION>_API_KEY`. The
value may be a string, a 0-arity function, or an `{m, f, a}` tuple,
resolved when each request runs, so a vault lookup or a refreshed
token needs no edit to Layer 1:

    config :my_app, MyApp.Integrations.Stripe,
      api_key: {MyApp.Vault, :fetch!, ["stripe"]}

A per-call `api_key:` overrides config. A credential set explicitly
on the request (`auth:`, the header, or the query param) is left
alone. The generated auth test (`<Int>Test`) has a working example of
each of these.

## Testing

The Mox mock is pre-wired:

    # config/test.exs (set by `gen`)
    config :my_app, MyApp.Integrations.Stripe.StripeApi,
      impl: MyApp.Integrations.Stripe.StripeApi.Mock

In a test:

    import Mox
    alias MyApp.Integrations.Stripe.StripeApi

    expect(StripeApi.Mock, :list_customers, fn _opts ->
      {:ok, %Req.Response{status: 200, body: %{"data" => []}}}
    end)

The generated external test is `:external`-tagged and excluded by
default. Run live calls with:

    mix test --include external

## Common pitfalls

* **Don't re-run `gen` to update** — it halts. Use `regen`.
* **Don't call Layer 1 or Layer 3 from business logic** — go
  through the Layer 2 behaviour so tests can stub it via the Mox
  mock.
* **Hand-edited a generated file? Add `hearth:owned`** before the
  next `regen`, or your changes will be overwritten.
* **Owning Layer 2 freezes its callbacks.** `regen` still rewrites
  Layer 3 from the spec, so the two can fall out of sync when
  operations change. Own both, or neither.
* **Edit `priv/hearth/<int>.yaml` to pull spec changes** — not the
  upstream spec path you originally passed to `gen`.
* **Set the credential** — for an authenticated spec, `gen` wires
  `config/runtime.exs` to read `<INTEGRATION>_API_KEY` from the
  environment. Set it before calling the integration.
