# Hearth

> **Hearth** — Strike sparks from OpenAPI specs into Req HTTP clients.
>
> _Phoenix burns to Ash; from the Hearth, new code is reignited._

Hearth is a set of Mix tasks that turn an OpenAPI 3.x specification into a
complete, three-layer Req HTTP integration: a raw client, a behaviour, and a
behaviour implementation — plus Mox plumbing, `Req.Test` plumbing, and
idempotent config patches. Integrations live in the hearth of every
application.

This document is the master context for the Hearth library repo: what we are
building, why, what works today, and what comes later. Consumer-facing usage
lives in `usage-rules.md`; history lives in git.

---

## The mental model

Hearth materializes the **three-layer HTTP client pattern** — from an
OpenAPI spec.

```
Layer 1  Raw Req client            (base URL, auth, request steps)
Layer 2  Behaviour + dispatcher    (the contract — every callsite goes through this)
Layer 3  Behaviour implementation  (delegates to Layer 1, one fn per operation)

+ Mox defmock                      (test/support/mocks.ex)
+ Config wiring                    (config.exs, test.exs, runtime.exs)
+ Tests                            (Req.Test auth test + :external live-API scaffold)
+ Pruned spec                      (priv/hearth/<int>.yaml — regen's source of truth)
```

The pattern's value: business logic depends on Layer 2 only. Tests stub the
behaviour with Mox without thinking about HTTP. Client tests exercise the real
Layer 1 against `Req.Test`. Layer 3 is pure plumbing — and plumbing is exactly
what generators are good at.

---

## The user experience

```bash
$ mix hearth.gen priv/specs/stripe.yaml --integration Stripe --domain Billing
```

`gen` creates the three layers, the auth test, the external-test scaffold and
the pruned spec, wires the Mox mock and config, and prints every file it
touched. It is **create-only**: re-running it on an existing integration halts.

```bash
$ mix hearth.regen stripe          # or stripe,send_grid — or --all
```

`regen` re-renders integrations from their pruned specs, honouring ownership
tokens. It takes integration names (the `--integration` value), never modules:
each pruned spec records its Layer 1 module in `x-hearth.module`. Running it straight after `gen` is a no-op. To pull in spec changes,
edit `priv/hearth/stripe.yaml` and re-run `regen`.

Only local spec files generate code today. URL and registry sources are
recognized and validated; generating from them needs the fetcher (pending).

---

## Built on Igniter

Hearth's Mix tasks are [Igniter](https://hexdocs.pm/igniter) tasks. Igniter is
the engine behind `mix ash.gen.*` and the same conventions apply here. We use
it because three of Hearth's hard requirements come almost free:

- **AST-aware patches.** `Igniter.Project.Config.configure/6` edits config
  files without regex. No string-templating fragility.
- **Composability.** `gen` composes `hearth.install` via
  `Igniter.compose_task/3`; tasks are tested in isolation with `Igniter.Test`.
- **Diff-aware UX.** Igniter's preview / `--yes` / dry-run flow shows every
  proposed change before it is written.

### Optional dep, standard fallback

Igniter is declared `optional: true` in `mix.exs`. Each task file uses the
canonical AshAi-style split:

```elixir
defmodule Mix.Tasks.Hearth.Install.Docs do
  @moduledoc false
  def short_doc, do: "..."
  def example, do: "mix hearth.install"
  def long_doc, do: "..."
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Hearth.Install do
    use Igniter.Mix.Task
    # ... real implementation
  end
else
  defmodule Mix.Tasks.Hearth.Install do
    use Mix.Task
    def run(_argv), do: # print "install igniter" message and exit 1
  end
end
```

Any other module that calls Igniter (or `Rewrite`/`Sourceror`, which arrive
with it) is wrapped in the same `if Code.ensure_loaded?(Igniter)` guard —
`Hearth.Fs.Content`, `Hearth.Gen.Patches`. Pure modules need no guard.

### Tasks

| Task                 | Purpose                                                                     |
| -------------------- | --------------------------------------------------------------------------- |
| `mix hearth.install` | One-time per-project setup (formatter import, `:hearth_domains` config).    |
| `mix hearth.gen`     | Generate the three-layer integration from an OpenAPI spec. Create-only.     |
| `mix hearth.regen`   | Regenerate integrations from their pruned specs, ownership-aware.           |

### `:hearth_domains` config

Hearth tracks managed integrations in application config — the same shape as
`:ash_domains`. `hearth.install` sets it to `[]`; each `gen` appends the
integration's **Layer 2** module:

```elixir
config :my_app, :hearth_domains, [
  MyApp.Billing.Stripe.StripeApi,
  MyApp.Notifications.SendGrid.SendGridApi
]
```

Set the value to `false` to opt out of tracking (`gen` leaves a non-list
untouched). `mix hearth.regen --all` does not read it — it walks
`priv/hearth/`, where each pruned spec names its own Layer 1 module. Open
question: does the list still earn its keep?

---

## Module layout

Default style is **Verbose**: the behaviour module repeats the integration
name. This is grep-friendly — you can search `StripeApi` and hit every callsite
without false positives from other `.Api` modules.

The layout is `<App>.<Domain>.<Integration>` plus per-layer suffixes.
The **domain** is the single namespace segment between the app and the
integration. It **defaults to `Integrations`**, is overridden wholesale
by `--domain`, and is dropped entirely by `--no-domain`.

```
# Default — domain is `Integrations`
App.Integrations.Stripe                  # Layer 1
App.Integrations.Stripe.StripeApi        # Layer 2
App.Integrations.Stripe.StripeApi.Req    # Layer 3
App.Integrations.Stripe.StripeApi.Mock   # Mox mock
App.Integrations.StripeTest              # Layer 1 auth test (test/)
App.Integrations.StripeExternalTest      # live-API scaffold (test/)

# --domain Billing — `Billing` replaces `Integrations`
App.Billing.Stripe
App.Billing.Stripe.StripeApi

# --no-domain — no namespace segment at all
App.Stripe
App.Stripe.StripeApi
```

Every layer derives from the Layer 1 module alone
(`Hearth.Render.ModuleNames.from_layer1/1`) — that is how `regen` needs only
the Layer 1 name. The OTP app name is auto-detected from `mix.exs`.

---

## Ownership model

`gen` only creates. `regen` updates, and generated files belong to Hearth by
default: `regen` overwrites them. This is intentional — OpenAPI specs change in
ways we cannot reasonably three-way merge, and most generated files are pure
plumbing that nobody wants to hand-edit.

Two opt-outs, both expressed as moduledoc tokens — visible at the top of the
file, survive reformatting, no sidecar config to forget about:

```elixir
defmodule App.Integrations.Stripe do
  @moduledoc """
  Raw Req client for Stripe.

  hearth:owned
  """
  # … your hand-edits …
end
```

| Token                  | Behavior on regen                                         |
| ---------------------- | --------------------------------------------------------- |
| _(none)_               | Overwrite silently. Default.                              |
| `hearth:owned`         | Skip entirely: `* skipping <path> (hearth:owned)`.        |
| `hearth:collaborating` | Prompt `y/N` per file (`--yes` / test mode accept).       |

The external test is a user-owned **scaffold**: created once, never
overwritten. A file whose token can't be read is skipped, never overwritten
(fail closed).

Layer 1 (the raw client) is the most common place to add `hearth:owned` — auth
flows, custom request steps, retry policies, and connection pool configuration
all live there and rarely round-trip back into the spec.

---

## v1 — first release scope

- [x] **OpenAPI 3.0 / 3.1 parsing**, local YAML or JSON file path.
- [x] **Operation → function** mapping. `operationId` → safe `snake_case`;
      missing operationId falls back to `<verb>_<path slug>`. Collisions get
      numeric suffixes.
- [x] **Path params** become positional function args (local `$ref`s
      resolved, undeclared template segments covered). **Query / body
      params** go through a final `opts` keyword (`params:`, `json:`, `form:`).
- [x] **Bearer and API-key auth** auto-wired from `securitySchemes`. OAuth2,
      OpenID Connect and HTTP basic leave a TODO in Layer 1.
- [x] **Verbose module style**, `--domain <Name>` / `--no-domain`.
- [x] **Ownership tokens** honoured by `regen`.
- [x] **Idempotent config patches** to `config/config.exs`, `config/test.exs`,
      `config/runtime.exs`, `test/support/mocks.ex`, `test/test_helper.exs`,
      and `mix.exs` (`test/support` in `elixirc_paths(:test)`, so the mock
      compiles in a plain `mix new` project).
- [x] **Generated tests**: a `Req.Test` auth test and an `:external`-tagged
      live-API scaffold.
- [x] **Generic response typing.** `{:ok, Req.Response.t()} | {:error, Exception.t()}`
      for every callback.
- [ ] **URL and registry sources** — needs the fetcher + cache (steps 4d–4f).
- [ ] **`--style {verbose|tight|split}`** — designed, not wired:
      `tight` → `…Stripe.Api` / `.Api.Req`; `split` → `…Stripe.Client` / `.Api`.

---

## v2 — close-to-shore roadmap

- [ ] **Custom function naming.** A `hearth.exs` file at project root lets the
      user override generated function names: `%{rename: %{"getEntitiesId" => :get_entity}}`.
- [ ] **Response typespecs from schemas.** Generate `@type list_entities_response :: %{…}`
      from `responses.<code>.content.application/json.schema`. Bumps Hearth from
      "generator" toward "client framework."
- [ ] **OAuth2 client credentials.** Auto-generate a token-refresh request step
      when `securitySchemes` declares `oauth2 + clientCredentials`.
- [ ] **Multiple auth schemes.** v1 auto-picks the primary. Planned: `gen`
      prompts; `--auth-scheme <name>` selects non-interactively; under `--yes`
      with several schemes and no flag, halt rather than guess.
- [ ] **Upstream drift check (`mix hearth.diff`).** Re-prune the spec at
      `x-hearth.source` with the pruned spec's selection and report changed /
      removed / added operations. Needs `source_sha256` + `pruned_sha256` in
      `x-hearth` to tell local edits from upstream changes. A later
      `hearth.sync` applies it.
- [ ] **Swagger 2.0 conversion.** Detect Swagger 2 input and convert to OpenAPI
      3 in memory before generating. Many real-world specs are still Swagger 2.
- [ ] **Pagination opinion.** Recognize common pagination markers (`cursor`,
      `page_token`, `Link` header) and offer an opt-in `Hearth.Pagination.stream/2`
      helper.

---

## Later — speculative

- [ ] **Pluggable adapters.** A `Hearth.Adapter.Behaviour` (`render_client/1`,
      `render_impl/1`) with Req as the built-in, and `--adapter` as the hook —
      e.g. a community Tesla adapter if anyone asks. Today Layer 1 and Layer 3
      render against Req directly.
- [ ] **Multipart uploads, streaming, server-sent events.** Each is a template
      special-case. Done when a real integration needs them.
- [ ] **Generated reusable request steps — `<App>.Hearth.Steps`.** A module
      generated into the consumer's project to hold hand-portable Req request
      steps that Layer 1's `new/1` wires in via `Req.Request.append_request_steps/2`.

      The motivating case: when every GET operation in the spec follows REST
      and declares no `requestBody`, Hearth can safely generate a step that
      promotes a GET *carrying* a binary body to a POST — for APIs
      (Elasticsearch-style search) that accept a query body only over POST.
      Because the spec proves no GET legitimately has a body, a body present
      at runtime is unambiguously the "too big for the query string" case.

      ```elixir
      # Layer 1 — generated new/1 gains the step
      def new(opts \\ []) do
        Req.new(base_url: @base_url, auth: {:bearer, credential(opts)})
        |> Req.Request.append_request_steps(
          post_binary_body: &MyApp.Hearth.Steps.post_binary_body/1
        )
        |> Req.merge(opts)
      end

      # MyApp.Hearth.Steps — generated once, hearth:owned, user-editable
      def post_binary_body(req) do
        with %{method: :get, body: <<_::binary>>} <- req do
          %{req | method: :post}
        end
      end
      ```

      `<App>.Hearth.Steps` is the home for any future reusable, user-editable
      step (retry policy, custom headers, pagination cursors): Hearth seeds
      it, the user evolves it.
- [ ] **Prefixed-ID URL shorthand.** Many APIs use type-prefixed resource IDs
      (Stripe: `cus_…` customers, `sub_…` subscriptions, `pi_…` payment
      intents). When a spec's IDs carry such prefixes, Hearth could generate a
      `parse_url/1` helper (or request step) in Layer 1 that expands a bare
      prefixed ID into its full resource path — keeping call sites short:

      ```elixir
      defp parse_url("sub_" <> _ = id), do: "/subscriptions/#{id}"
      defp parse_url("cus_" <> _ = id), do: "/customers/#{id}"
      defp parse_url(url), do: url

      def request(url, opts \\ []), do: Req.request(new(url: parse_url(url)), opts)
      def request!(url, opts \\ []), do: Req.request!(new(url: parse_url(url)), opts)
      ```

      So `Stripe.request!("cus_123")` resolves to `/customers/cus_123`. Open
      question: where the prefix → path mapping comes from — inferred from the
      spec's path patterns, or a curated registry entry per API.
- [ ] **AsyncAPI input.** Generate websocket / pub-sub clients with the same
      three-layer shape. Sister project, not Hearth itself.
- [ ] **GraphQL SDL input.** Different enough that it probably wants its own
      generator. Listed here only to acknowledge "we thought about it."
- [ ] **Version-aware collision naming.** v1's collision strategy is a bare
      numeric suffix — two operations both named `validate` become `validate`
      and `validate_2`, which says nothing about *why* they differ. When the
      colliding operations differ by an API version carried in the URL path
      (`/v2/notices/validate` vs `/v3/notices/validate`) or a version header,
      Hearth could derive the suffix from that version instead:

      ```elixir
      @impl true
      def validate_v2(opts \\ []) do
        TED.request("/v2/notices/validate", [method: :post] ++ opts)
      end

      @impl true
      def validate_v3(opts \\ []) do
        TED.request("/v3/notices/validate", [method: :post] ++ opts)
      end
      ```

      `validate_v2` / `validate_v3` self-documents the split. The bare numeric
      suffix stays the fallback for collisions with no discernible version
      difference.

---

## Non-goals

These are deliberate omissions, not oversights:

- **No runtime macro mode.** Hearth writes files to disk, full stop. Macros
  hide the generated code from grep, IDEs, and diffs, and make compile errors
  harder to read. The Mix-task ergonomics of `phx.gen.*` and `ash.codegen` are
  the model.
- **No three-way merging of spec changes into hand-edited files.** Diff and
  ownership tokens are the boundary. Anything more is a swamp.
- **No opinion on Ash placement.** A generated `StripeApi` is a plain Elixir
  module that an Ash action can call. Hearth does not generate Ash resources.
- **No code style enforcement.** Generated files are run through
  `Code.format_string!/1`. Beyond that, Hearth does not have opinions on the
  project's Credo config or naming conventions.

---

## Library internals

```
lib/
  hearth.ex                    # public overview module (hex docs front door)
  mix/tasks/
    hearth.install.ex          # one-time project setup
    hearth.gen.ex              # spec → integration (create-only)
    hearth.regen.ex            # pruned spec → refreshed integration
  hearth/
    registry.ex                # curated, versioned spec shortcuts (stripe@…)
    spec/                      # pure: decoded spec → data
      source.ex                # argv → {:file | :url | :registry | :error, _}
      loader.ex                # sniff format, decode YAML/JSON
      operation.ex             # paths → %Operation{}; safe names, path args
      filter.ex                # --tag parsing + selection
      auth.ex                  # securitySchemes → auth strategy
      servers.ex               # servers → default / test base URLs
      base_path.ex             # shared path prefix (stops at templated segments)
      prune.ex                 # spec → pruned spec + YAML encoding
      meta.ex                  # the x-hearth block in the pruned spec
    render/                    # pure: data → source strings
      module_names.ex          # every layer's module from Layer 1
      layer1.ex  layer2.ex  layer3.ex
      tests.ex                 # Req.Test auth test + :external scaffold
      mocks.ex                 # test/support/mocks.ex
    integration/
      manifest.ex              # the files an integration consists of (gen + regen)
    gen/
      messages.ex              # gen's user-facing text, tag discovery
      patches.ex               # deps, mock, test_helper, config (Igniter-guarded)
    regen/
      messages.ex              # regen's user-facing text
    fs/
      ownership.ex             # hearth:owned / hearth:collaborating
      content.ex               # read through Igniter's Rewrite (Igniter-guarded)
test/
  hearth/…  mix/tasks/hearth/… # mirror lib/
  fixtures/specs/              # OAI petstore (3.0) + tictactoe (3.1)
  generated/<case>/…golden     # golden snapshots of everything gen writes
  golden_test.exs  usage_rules_test.exs
```

Spec parsing leans on `yaml_elixir` (read) + `ymlr` (write) + the stdlib
`JSON`. **`open_api_spex` was evaluated and rejected:** its scope is request
validation, it has no pruning, and its decoder raises on OAS 3.1 specs.

File-writing and config patching are delegated to Igniter — we do not maintain
our own diff/patch logic. Renderers build source as strings (typespec-heavy
output reads better as text) and run it through `Code.format_string!/1`, which
doubles as the syntax check.

---

## Current state

What exists, condensed. The blow-by-blow is in git history.

- **`hearth.install`** — adds `:hearth` to `.formatter.exs` `import_deps`,
  initializes `hearth_domains: []` (existing values, including `false`,
  survive), and prints a notice with three branches: first install, repeat
  with changes, repeat no-op.
- **`hearth.gen` pipeline** — `Source.resolve/1` classifies the argument;
  install is auto-composed (gated: silent if install would be a no-op,
  `--yes`/test mode accept, else prompt). For a file: sniff → existence via
  `Igniter.exists?/2` → read through Rewrite → decode → `Operation.extract/1`
  → selection (`--tag` filter, or the `--n-operations` gate, default 25, which
  halts with a copy-and-edit tag-discovery command). `--integration` and
  `--domain` must camelize to a single alias segment. If **any** generated file
  already exists, gen halts. Otherwise it writes the `Manifest` files, the
  pruned spec, and applies `Patches`.
- **`--list`** — no source: registry shortcuts; a shortcut: its versions; a
  file: the tag-discovery listing. Output goes through `Mix.shell().info/1`
  with `quiet_on_no_changes?` set.
- **Registry** — Stripe only: 14 dated versions (basil / clover / dahlia) plus
  a floating `latest`; codename and date aliases resolve at lookup and are
  hidden from listings.
- **Operations** — local `#/components/parameters/*` refs resolve; an
  operation-level param overrides a path-level one (same `name` + `in`); every
  `{x}` in the path template becomes a path param. Function names and path
  args are made safe (reserved words, `impl`, `module_info`, `opts` get `_`;
  a leading digit gets `op_` / `param_`) and deduped with suffixes that skip
  taken names.
- **Layer 1** — `@base_url` from the default server plus the folded base path
  (a placeholder + TODO when the spec has no servers), overridable via
  `config … base_url:`; `new/1` (mirrors `Req.new/1`, ends with
  `Req.merge(opts)`), `request/2`, `request!/2`. Bearer / API-key (header or
  query) read `api_key` from app config keyed by the Layer 1 module, with an
  `:api_key` override on `new/1`.
- **Layer 2** — per operation a `@callback` plus a delegating `def`
  (summary/description as `@doc`), dispatching through
  `Application.get_env(@otp_app, __MODULE__)[:impl] || __MODULE__.Req`. The
  moduledoc ends with a `## Source` footer.
- **Layer 3** — `@behaviour` Layer 2; each function calls
  `<Layer1>.request/2` with the path interpolated in one regex pass; `:get`
  omits `method:`.
- **Generated tests** — `<Int>Test`: `Req.Test` auth assertions, wrapped in
  `if Code.ensure_loaded?(Plug.Conn)` (no `plug` dep is added — `req` declares
  it optional for all envs). `<Int>ExternalTest`: `@moduletag :external`, one
  test per operation calling Layer 3 directly; `test_helper.exs` excludes
  `:external`.
- **Wiring (`Patches`)** — adds `{:req, "~> 0.5"}` and
  `{:mox, "~> 1.0", only: [:test]}`, queues `deps.get` when that changed
  `mix.exs`; `defmock` appended idempotently; `test/support` added to
  `elixirc_paths(:test)` via `Igniter.Project.Test.ensure_test_support/1`
  (a project that already sets `elixirc_paths` is left alone); `config/runtime.exs` credential (prod
  raises, dev falls back to `"DEV_NO_<INT>_API_KEY"`); `config/test.exs`
  `impl:` mock and a non-prod `base_url:`; extra servers as commented
  alternates; `:hearth_domains` appended.
- **Pruned spec** — `Prune.prune/2` keeps the selected paths and the
  components reachable by `$ref` from them (`securitySchemes` whole), encoded
  with conventional top-level key order, plus an `x-hearth` block
  (`module`, `base_path`, `source`).
- **`hearth.regen`** — takes comma-separated integration names (each must be a
  single alias segment; `stripe` → `priv/hearth/stripe.yaml`) or `--all`
  (every `priv/hearth/*.yaml`); neither, or both, halts. Per spec: derives
  every module from `x-hearth.module` (halts if missing or not a module name),
  takes `base_path` / `source` from `x-hearth` (recomputes if absent; halts if
  a path falls outside the recorded base path), and renders the same
  `Manifest`. Any failure halts the whole run. Refreshes code only — never
  config or the pruned spec — except under `--module <Layer1>`: exactly one
  name, module must end in it. It creates the new modules (halts if any
  exist; the old ones are untouched), rewrites only the `module:` value in the
  pruned spec (`Meta.replace_module/3`, re-encodes as a fallback), and wires
  config via `Patches.wire/2` with `replaces:` — the old Layer 2 is swapped
  for the new one in `:hearth_domains` (in place; appended if absent).
  `--remove-old` (requires a `--module` that differs from the current one)
  also `Igniter.rm`s the old untokened tracked files — scaffold, owned,
  collaborating and unreadable files are kept and listed — and
  `Patches.unwire/3` cuts its config entries, alternates and `defmock`
  by Sourceror range from the text (AST removal crashes Sourceror on its
  trailing-comment blocks and drops comments).

---

## Load-bearing contracts

Learned the hard way; every change must keep them:

- **Every commit produces visibly different behavior for distinct user
  inputs.** Skeletons that no-op identically on every input are misleading.
- **Consumer-facing text never references internal docs or step numbers.**
  Enforced in `gen_test.exs` "consumer-facing docs".
- **`long_doc` and `usage-rules.md` only advertise what works today.**
  Lock-in tests refute stale wording and copy-paste traps.
- **Tasks that need install state open with the gated compose pattern**
  (speculative `compose_task` + `Igniter.has_changes?/2`).
- **`gen` is create-only; `regen` straight after `gen` is a no-op.** Both are
  tested. `install` re-runs are no-ops too.
- **`gen` and `regen` render from one `Manifest`.** Add a generated file there,
  not in a task.
- **Generator output changes come with regenerated golden files** in the same
  commit (`HEARTH_UPDATE_GOLDEN=1 mix test test/golden_test.exs`), and the
  snapshot diff gets reviewed.
- **Generated code must compile cleanly** — names go through
  `Operation.function_name/1` / `path_args/1`; a gen test compiles the layers
  of an adversarial spec and asserts zero diagnostics.
- **Ownership fails closed.** Unreadable → skipped, never overwritten.

---

## Working in this repo

- **TDD throughout.** Write the failing test first. Task tests use
  `Igniter.Test` — `test_project/1`, `assert_creates/3`,
  `assert_unchanged/1`, `apply_igniter!/1`. In test mode `Igniter.exists?/2`
  only sees the virtual fs, so fixtures go through `test_project(files: …)`.
- **Verify before committing:** `mix compile --warnings-as-errors --force`,
  `mix format --check-formatted`, `mix credo --strict`, `mix test` (CI runs
  the same).
- **Tiny well-named modules.** The renderer-per-layer split is deliberate. If
  `render/layer3.ex` grows past 300 lines, split by concern before adding
  another feature.
- **Public API discipline.** Only `Hearth` and the three Mix tasks are public.
  Everything under `lib/hearth/` is `@moduledoc false`.
- **Hex docs are the front door.** The README's first 30 lines must be enough
  to decide whether to install Hearth.

### Pending

- **Steps 4d–4f** — `Hearth.Spec.Cache`, `Hearth.Spec.Fetcher` (Req + cache;
  bundles `latest` resolution — TODO on the `latest` entry in
  `lib/hearth/registry.ex`), end-to-end URL/registry codegen.
- **Open review items:**
  - auth corner cases — does a query API key survive a caller's `params:`
    (`Req.merge`)? A per-call `api_key:` through Layer 2/3 reaches
    `Req.request/2` as an unknown option;
  - `Ownership.classify/1` scans the whole file, not just the `@moduledoc`;
  - `gen_test.exs` (~1500 lines) wants splitting by concern.

---

## Commit conventions

Follow Conventional Commits.

```
feat: support OpenAPI 3.1 webhooks
fix: dedupe config patches when --integration is rerun
refactor: extract auth strategy from layer1 renderer
docs: worked example for OAuth2 TODO
test: golden file for petstore spec
```

PRs that change generator output must include the regenerated golden files in
the same commit.
