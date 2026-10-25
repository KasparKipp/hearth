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

then run `mix deps.get` and `mix hearth.install` (formatter import +
`:hearth_domains` config). Hearth's tasks run on Igniter, which Hearth
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

## Update integrations with `regen`

    mix hearth.regen stripe              # one integration
    mix hearth.regen stripe,send_grid    # several
    mix hearth.regen --all               # every pruned spec

Name an integration by the `--integration` it was generated with, not
by its module. With no name and no `--all`, `regen` halts.

`regen` reads `priv/hearth/<int>.yaml` (the pruned spec — the
versioned source of truth) and re-renders the three layers plus the
auth test. If any named integration fails, nothing is written. It does **not** re-run config patches or rewrite the
pruned spec.

To move one integration into a new namespace:

    mix hearth.regen stripe --module MyApp.Payments.Stripe

The module must end in the integration name. `--module` creates the
new modules (halting if any exist), points `x-hearth.module` at them,
wires their mock and config, and swaps the old Layer 2 for the new one
in `:hearth_domains`. The old modules and their other config stay
untouched — delete them once callers use the new module.

Add `--remove-old` to remove the old module in the same run — its
files, config entries and `defmock`:

    mix hearth.regen stripe --module MyApp.Payments.Stripe --remove-old

Files you've claimed (an ownership token, or the external test
scaffold) are kept and listed. `--remove-old` without `--module` halts.

To pull in upstream spec changes, edit `priv/hearth/<int>.yaml` and
re-run `regen`.

The pruned spec ends with an `x-hearth` block recording the Layer 1
`module`, the base path `gen` folded into the client's base URL, and
the original spec source. Leave it as is: `regen` derives every module
from `module` and halts without it. A new path must sit under the
recorded `base_path` — `regen` halts otherwise.

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

    import Mox
    alias MyApp.Integrations.Stripe.StripeApi

    expect(StripeApi.Mock, :list_customers, fn _opts ->
      {:ok, %Req.Response{status: 200, body: %{"data" => []}}}
    end)

The generated external test is `:external`-tagged and excluded by
default. Run live calls with:

    mix test --include external

## Tracked integrations — `:hearth_domains`

`hearth.install` initializes `config :<app>, hearth_domains: []`.
Each `gen` appends the new Layer 2 module. Set the value to `false`
to opt out of tracking.

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
