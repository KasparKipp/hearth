# Hearth — Usage Rules

Hearth turns an OpenAPI 3.x (or Swagger 2.0) spec into a complete three-layer Req
HTTP client: a raw client, a behaviour, and a Req implementation,
plus Mox plumbing, a `Req.Test` auth test, an external integration
test, and idempotent config patches. The generator is opinionated —
follow the conventions below and the generated code stays clean.

## Setup

With Igniter (recommended):

    mix igniter.install hearth

Or manually — add to `mix.exs`:

    {:hearth, "~> 0.1", only: [:dev, :test], runtime: false},
    {:igniter, "~> 0.5", only: [:dev, :test]}

then run `mix deps.get` and `mix hearth.install` (formatter import).
Hearth's tasks run on Igniter, which Hearth
declares as an optional dependency — without `igniter` in your deps the
tasks only print an install hint.

## Generate an integration

    mix hearth.gen <source> --integration <Name>

A source is a local spec file (`.yaml`, `.yml` or `.json`), an http(s)
URL, or a registry shortcut (`stripe@2026-04-22.dahlia`; bare `stripe`
means `stripe@latest`). All three generate code. A shortcut defaults
`--integration` to its name.

    mix hearth.gen priv/specs/acme.yaml --integration Acme
    mix hearth.gen https://acme.example.com/openapi.json --integration Acme
    mix hearth.gen acme@1.0     # a shortcut names the integration itself

URLs and shortcuts are fetched on every `gen`, `regen --sync` and
`diff` — nothing is cached — and the `.hearth.exs` `source:` keeps the
source as given, so `stripe@latest` follows upstream. Plain `regen`
never fetches.

A Swagger 2.0 source is converted to OpenAPI 3.0 first. The pruned spec
is OpenAPI 3, and `overrides:` address that form. A spec without a host
gets a placeholder base URL: set `base_url:` in config, or say where it
comes from with the entry's `base_url:` (see "Where values come from").

Declare your own shortcuts in `.hearth.exs` — same shape as Hearth's
built-in registry. A version points at a URL or a file;
`{:alias, version}` points at another version. A name you declare
shadows a built-in one:

    [
      registry: %{
        "acme" => %{
          "1.0" => "https://acme.example.com/openapi-1.0.json",
          "1.1" => "priv/specs/acme-1.1.json",
          "latest" => {:alias, "1.1"}
        }
      },
      integrations: [...]
    ]

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
`gen` replaces the integration's `.hearth.exs` entry, keeping its
`overrides:`.

## Update integrations with `regen`

    mix hearth.regen stripe              # one integration
    mix hearth.regen stripe,send_grid    # several
    mix hearth.regen --all               # every integration in .hearth.exs

Name an integration by the `--integration` it was generated with, not
by its module. With no name and no `--all`, `regen` halts.

`regen` reads `priv/hearth/<int>.yaml` (the pruned spec — the
versioned source of truth) and re-renders the three layers plus the
auth test. If any named integration fails, nothing is written. It does **not** re-run config patches or rewrite the
pruned spec — unless you pass `--sync`.

The `.hearth.exs` entry's `tags:` decides which operations the pruned
spec holds. To add or drop operations, edit `tags:` and re-prune from
`source:`:

    mix hearth.regen stripe --sync

`--sync` rewrites the pruned spec and `tags:`, lists the operations it
added and removed, and regenerates. Plain `regen` halts when `tags:`
no longer matches the pruned spec, pointing at `--sync`. Don't add or
remove operations in `priv/hearth/<int>.yaml` by hand: `regen` halts,
and `--sync` would undo it.
`--sync --all` asks before re-pruning everything (`--yes` skips the
question); run `mix hearth.diff --all` first to see what it would change.

When a function goes away — renamed, or now covered by a `prefixed_ids`
function — `--sync` asks to rename its calls in lib and test, Mox
expectations included. It asks before appending external tests for new
functions, and names tests that still call a removed operation.
`--yes` accepts both questions.

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

To pull in a newer version of the spec, point `source:` at it and run
`mix hearth.regen <int> --sync`.

## `.hearth.exs`

`gen` records each integration in `.hearth.exs` at the project root,
keyed by its snake_case name:

    [
      integrations: [
        stripe: [
          module: MyApp.Integrations.Stripe,
          source: "priv/specs/stripe.yaml",
          source_sha256: "9f86d0…",
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
* `source_sha256` — the source's checksum at the last `gen` or
  `--sync`, so `mix hearth.diff` can tell whether it changed since.
* `base_path` — the path prefix `gen` folded into the client's base
  URL. A new path in the pruned spec must sit under it — `regen` halts
  otherwise.
* `tags` — every tag in the source spec and what `gen` selected from
  it: `:all`, `:none`, or `include:` / `exclude:` lists of
  operationIds. Operations without a tag go under `untagged:`.
* `auth` — the spec's security schemes and the one the client wires
  (`scheme:`); see below.
* `overrides` — your corrections to the source spec; see below.
* `headers` — headers the client sends on every call; see below.
* `base_url` — where the base URL comes from, when not from the spec;
  see "Where values come from".
* `sources` — several specs merged into one integration, in place of
  `source`; see below.

Commit it alongside `priv/hearth/`. The pruned spec itself is plain
OpenAPI.

## Auth

`gen` records the spec's security schemes and wires the first one
Hearth supports, HTTP basic only when nothing else is:

    auth: [
      scheme: "bearerAuth",
      available: [basicAuth: "basic", bearerAuth: "bearer"]
    ]

To use another, change `scheme:` and run `mix hearth.regen <int> --sync`.

## Overrides

`overrides:` corrects the source spec. Write it against the source's
own paths and operationIds:

    stripe: [
      source: "stripe@2026-04-22.dahlia",
      overrides: [
        tags: [
          Customers: ["get /v1/customers", "post /v1/customers", "GetCustomersCustomer"],
          Subscriptions: ["/v1/subscriptions*"]
        ],
        operation_ids: %{"GetCustomersCustomer" => "GetCustomer"},
        patches: %{
          "/components/securitySchemes/bearerAuth" => %{"type" => "http", "scheme" => "bearer"},
          "/security" => [%{"bearerAuth" => []}]
        }
      ],
      ...
    ]

* `tags` — tag the operations an entry matches: a path glob (`*`
  matches anything, `/` included), a method and a glob, or an
  operationId.
* `operation_ids` — rename an operation, found by its operationId or by
  `"method /path"`. The function follows: `GetCustomer` → `get_customer`.
* `patches` — set a JSON pointer to a value; `nil` removes it, `-`
  appends to a list. Applied first, to the OpenAPI 3 form.

Before the first `gen`, write the entry with just `overrides:`. Later,
edit them and run `mix hearth.regen <int> --sync`. An override that
matches nothing is reported.

## Prefixed ids

For APIs with type-prefixed ids (Stripe's `cus_…`, `sub_…`), add
functions that take an id and find its resource:

    stripe: [
      prefixed_ids: [
        functions: [get_by: :get, update: :post, destroy: :delete],
        prefixes: [cus: "GetCustomer", pi: "/v1/payment_intents/{intent}"]
      ],
      ...
    ]

`StripeApi.retrieve("cus_123")` sends `GET /customers/cus_123`, and the
raw client's `request/2` takes a prefixed id as a path too. Name the
functions as you like; each maps to an HTTP method. A prefix names its
resource by an operation on it (after any `operation_ids` renames) or by
its path. The operations aren't generated unless selected, so a few
functions cover many resources.

## Several sources

To build one integration from several specs of one API (modules behind
one gateway), write the entry before `gen` with `sources:`, then run
`gen` without a source:

    shop: [sources: [items: "priv/specs/items.json", orders: "orders@1.2"]]

    mix hearth.gen --integration Shop --tag "Items:get_item" --tag "Orders:get_order"

Each source's server path joins its paths (`/items/v1/items/{id}`).
Components the sources define differently get the source key as a
prefix (`items_address`). When one that was shared splits, `diff` says
which source to pin with `overrides: [shared: %{"schemas/address" =>
:items}]`. `--source` doesn't apply.

## Headers

To send a header on every call, map it to where its value comes from
(see "Where values come from"), then run `mix hearth.regen <int>`:

    stripe: [
      headers: ["stripe-account": :account],
      ...
    ]

A bare key resolves like the credential: a per-call `account:`, else
config, as a string, a 0-arity function or an `{m, f, a}` tuple.
`config/runtime.exs` reads `<INTEGRATION>_<KEY>` (`STRIPE_ACCOUNT`). A
header set on the request wins; a missing value raises. `gen` points
out required headers nothing sends yet.

## Check for drift with `diff`

    mix hearth.diff stripe               # one integration (or stripe,send_grid, or --all)
    mix hearth.diff stripe --source priv/specs/stripe-2026-10.yaml

`diff` re-prunes the integration's `source:` with its `tags:` and
compares the result with `priv/hearth/<int>.yaml`. It lists every
change — operations added, removed, moved or renamed; parameters,
request bodies and responses; component schemas (properties, required
fields, enum values, types) — and marks the breaking ones.
Documentation-only changes are ignored. It also lists new upstream
operations `tags:` doesn't select yet, without failing.

An upstream operationId rename (same method and path) is drift but not
breaking: `--sync` renames the generated function and keeps the
operation selected — `tags:` follows the new id — and the report names
the call sites to rename (`list_pets → list_all_pets`).

`diff` writes nothing and exits non-zero on drift — run it in CI.
`--fail-on breaking` fails only on breaking changes. `--source`
previews another spec (e.g. a newer version) without touching
`.hearth.exs`. To apply drift, point `source:` at the spec you want
and run `mix hearth.regen <int> --sync`.

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

For a bearer, API-key or HTTP basic spec, the credential comes from the
`:api_key` option, or else from config (for basic, `user:password`):

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

## Where values come from

The credential (`auth: [credential: …]`), each `headers:` value and the
base URL (`base_url:`) take one of three forms. A per-call option always
comes first:

    acme: [
      auth: [scheme: "bearerAuth", credential: [resolve: {MyApp.Tenancy, :token}, options: [:tenant]]],
      headers: ["x-app-key": :app_key, "x-tenant-id": [option: :tenant_id]],
      base_url: :base_url
    ]

* `key` — the `key` option, else config; `config/runtime.exs` reads
  `<INTEGRATION>_<KEY>`. The default credential is `:api_key`.
* `[option: key]` — per call only: never read from config, nothing in
  `config/runtime.exs`. A call without it raises.
* `[resolve: {M, :f}, options: [...]]` — `M.f/1` when each request
  runs, given those options; it must return a string. The credential
  still takes a per-call `api_key:` first, the base URL a `base_url:`.
  A resolved base URL is the host (say, a customer's gateway): the
  client appends the spec's base path (`/v1`). A `base_url:` passed per
  call is used as is.

Then run `mix hearth.regen <int>`. A value that moves off config leaves
its `config/runtime.exs` line behind; `regen` names it for you to
delete.

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
