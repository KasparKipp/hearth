# Hearth

> **Hearth** — Strike sparks from OpenAPI specs into Req HTTP clients.
>
> _Phoenix burns to Ash; from the Hearth, new code is reignited._

Hearth is a Mix task that turns an OpenAPI 3.x specification into a complete,
three-layer Req HTTP integration: a raw client, a behaviour, and a behaviour
implementation — plus Mox plumbing, `Req.Test` plumbing, and idempotent config
patches. Integrations live in the hearth of every application.

This document is the master context for the Hearth library repo. It defines
what we are building, why, what is in v1, and what comes later.

---

## The mental model

Hearth materializes the **three-layer HTTP client pattern** — from an
OpenAPI spec.

```
Layer 1  Raw Req client            (base URL, auth, request steps)
Layer 2  Behaviour                 (the contract — every callsite goes through this)
Layer 3  Behaviour implementation  (delegates to Layer 1, one fn per operation)

+ Mox defmock                      (test/support/mocks.ex)
+ Config wiring                    (config.exs, test.exs)
+ Test scaffolding                 (Mox stub + Req.Test plug fixtures)
```

The pattern's value: business logic depends on Layer 2 only. Tests stub the
behaviour with Mox without thinking about HTTP. Client integration tests
exercise the real Layer 1 against `Req.Test`. Layer 3 is pure plumbing — and
plumbing is exactly what generators are good at.

---

## The user experience

```bash
$ mix hearth.gen priv/specs/stripe.yaml \
    --integration Stripe \
    --domain Billing

* creating lib/app/billing/stripe.ex
* creating lib/app/billing/stripe/stripe_api.ex
* creating lib/app/billing/stripe/stripe_api/req.ex
* creating test/app/billing/stripe/stripe_api_test.exs
* patching test/support/mocks.ex            (+1 line)
* patching config/config.exs                (+3 lines)
* patching config/test.exs                  (+2 lines)

  4 files created · 3 files patched · 0 skipped

Next steps:
  • set STRIPE_API_KEY in your environment
  • run `mix test test/app/billing/stripe/stripe_api_test.exs`
```

Re-running the same command on an unchanged spec is a no-op. Re-running after a
spec update overwrites generated files (see **Ownership** below) and skips
config patches that are already in place.

---

## Built on Igniter

Hearth's Mix tasks are [Igniter](https://hexdocs.pm/igniter) tasks. Igniter is
the engine behind `mix ash.gen.*` and the same conventions apply here. We use
it because three of Hearth's hard requirements come almost free:

- **AST-aware patches.** `Igniter.Project.Config.configure/6` edits `config.exs`
  without regex. `Igniter.Project.Module.create_module/4` adds modules
  idempotently. No string-templating fragility.
- **Composability.** `mix hearth.gen` decomposes into sub-tasks (one per layer,
  plus config patches) that `Igniter.compose_task/3` chains. Each sub-task is
  tested in isolation.
- **Diff-aware UX.** Igniter's preview / `--yes` / dry-run mode maps cleanly
  onto the `hearth:collaborating` ownership token — collaborating files just
  surface the same diff prompt Igniter already shows.

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

Consumers who do not want Igniter still get a working error message and a
pointer to the install instructions.

### Tasks

| Task                | Status     | Purpose                                                                    |
| ------------------- | ---------- | -------------------------------------------------------------------------- |
| `mix hearth.install`| in progress| One-time per-project setup (formatter imports, `:hearth_domains` config). |
| `mix hearth.gen`    | planned    | Generate the three-layer integration from an OpenAPI spec.                |

### `:hearth_domains` config

Hearth tracks managed integrations in application config — the same shape as
`:ash_domains`:

```elixir
config :my_app, :hearth_domains, [
  MyApp.Billing.Stripe,
  MyApp.Notifications.SendGrid
]
```

Set the value to `false` (or omit the key entirely after `hearth.install`
sets it to `[]`) to opt out of tracking. The list is the source of truth for
future `mix hearth.regen --all` and compile-time validation.

---

## Module layout

Default style is **Verbose**: the behaviour module repeats the integration
name. This is grep-friendly — you can search `StripeApi` and hit every callsite
without false positives from other `.Api` modules.

The layout is `<App>.<Domain>.<Integration>` plus per-layer suffixes.
The **domain** is the single namespace segment between the app and the
integration. It **defaults to `Integrations`**, is overridden wholesale
by `--domain`, and is dropped entirely by `--no-domain` — Hearth does
not lock you into a fixed naming pattern.

```
# Default — domain is `Integrations`
App.Integrations.Stripe                  # Layer 1
App.Integrations.Stripe.StripeApi        # Layer 2
App.Integrations.Stripe.StripeApi.Req    # Layer 3
App.Integrations.Stripe.StripeApi.Mock   # Mox mock

# --domain Billing — `Billing` replaces `Integrations`
App.Billing.Stripe
App.Billing.Stripe.StripeApi

# --no-domain — no namespace segment at all
App.Stripe
App.Stripe.StripeApi
```

Other styles available via `--style`:

```
--style tight    # App.…Stripe.Api / .Api.Req       (less repetitive)
--style split    # App.…Stripe.Client / .Api / …    (explicit Client suffix)
```

The integration name (`Stripe`) is required. The domain is optional —
it defaults to `Integrations`, `--domain <Name>` overrides it, and
`--no-domain` drops it. The OTP app name is auto-detected from `mix.exs`.

---

## Ownership model

Generated files belong to Hearth by default. Re-running overwrites them. This
is intentional: OpenAPI specs change in ways we cannot reasonably three-way
merge, and most generated files are pure plumbing that nobody wants to hand-edit.

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

| Token                  | Behavior on regen                                                    |
| ---------------------- | -------------------------------------------------------------------- |
| _(none)_               | Overwrite silently. Default.                                         |
| `hearth:owned`         | Skip entirely. Log: `* skipping <path> (hearth:owned)`.              |
| `hearth:collaborating` | Show diff, prompt `y/N` per file. CI runs treat no-answer as `skip`. |

Layer 1 (the raw client) is the most common place to add `hearth:owned` — auth
flows, custom request steps, retry policies, and connection pool configuration
all live there and rarely round-trip back into the spec.

---

## Adapter architecture

The HTTP backend is pluggable from day one. Req is the built-in adapter and the
recommended default — it matches the existing `http-client-pattern` skill.

```elixir
# Built-in
Hearth.Adapter.Req       # generates Layer 1 + Layer 3 against Req
Hearth.Adapter.Behaviour # the contract a custom adapter implements
```

A custom adapter implements two callbacks: `render_client/1` (Layer 1) and
`render_impl/1` (Layer 3). Layer 2, Mox, and config wiring are adapter-agnostic
— they live in the core templates.

`--adapter MyApp.Hearth.Tesla` is the override hook. v1 ships Req only. v2 may
add a community Tesla adapter if there is demand.

---

## v1 — first release scope

The minimum useful surface:

- [ ] **OpenAPI 3.0 / 3.1 parsing**, local YAML or JSON file path only.
- [ ] **Operation → function** mapping. `operationId` → `snake_case`. Missing
      operationId falls back to `<verb>_<path slug>` (e.g.
      `get_entities_id_posts`). Collisions get numeric suffixes.
- [ ] **Path params** become positional function args, in spec order.
      **Query / body params** go through a final `opts` keyword (the Req
      conventions: `params:`, `json:`, `form:`).
- [ ] **Bearer and API-key auth** auto-wired from `securitySchemes`. OAuth2
      leaves a `# TODO: implement OAuth2 token refresh as a request step.`
      comment in the generated Layer 1.
- [ ] **Verbose module style** as default. `--style {verbose|tight|split}`
      as a flag. `--domain <Name>` sets the namespace segment between the
      app and the integration (default `Integrations`); `--no-domain`
      drops it.
- [ ] **Ownership tokens** (`hearth:owned`, `hearth:collaborating`) honored on
      regeneration. No-token files overwrite silently.
- [ ] **Idempotent config patches** to `config/config.exs`, `config/test.exs`,
      and `test/support/mocks.ex`. Re-runs detect existing lines and skip; no
      duplication.
- [ ] **Scaffolded test files**: one `_test.exs` per behaviour, with a Mox stub
      example and a `Req.Test` plug example. User fills in real assertions.
- [ ] **Generic response typing.** `{:ok, Req.Response.t()} | {:error, Exception.t()}`
      for every callback. (Typed response structs from schemas are a v2 thing.)

---

## v2 — close-to-shore roadmap

- [ ] **Custom function naming.** A `hearth.exs` file at project root lets the
      user override generated function names: `%{rename: %{"getEntitiesId" => :get_entity}}`.
- [ ] **Response typespecs from schemas.** Generate `@type list_entities_response :: %{…}`
      from `responses.<code>.content.application/json.schema`. Bumps Hearth from
      "generator" toward "client framework."
- [ ] **OAuth2 client credentials.** Auto-generate a token-refresh request step
      when `securitySchemes` declares `oauth2 + clientCredentials`.
- [ ] **Spec from URL.** `mix hearth.gen https://api.example.com/openapi.yaml …`
      Fetches and caches into `priv/hearth/cache/`. Useful for upstream APIs
      that publish their spec.
- [ ] **Swagger 2.0 conversion.** Detect Swagger 2 input and convert to OpenAPI
      3 in memory before generating. Many real-world specs are still Swagger 2.
- [ ] **Pagination opinion.** Recognize common pagination markers (`cursor`,
      `page_token`, `Link` header) and offer an opt-in `Hearth.Pagination.stream/2`
      helper.

---

## Later — speculative

- [ ] **Tesla adapter.** If anyone asks.
- [ ] **Multipart uploads, streaming, server-sent events.** Each is a template
      special-case. Done when a real integration in this codebase needs them.
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
      and `validate_1`, which says nothing about *why* they differ. When the
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
- **No code style enforcement.** Generated files run through `mix format` after
  writing. Beyond that, Hearth does not have opinions on the project's
  Credo config or naming conventions.

---

## Library internals (planned)

```
lib/
  hearth.ex              # public API surface (currently a stub)
  mix/tasks/
    hearth.install.ex    # one-time project setup (Igniter)
    hearth.gen.ex        # spec → integration generator (planned)
  hearth/
    spec/
      loader.ex          # YAML/JSON → normalized internal map
      operation.ex       # one parsed OpenAPI operation
      auth.ex            # securitySchemes → auth strategy struct
    render/
      layer1.ex          # via the adapter
      layer2.ex          # behaviour template
      layer3.ex          # via the adapter
      mocks.ex           # Mox.defmock line
      config.ex          # config/* patches
      tests.ex           # scaffolded *_test.exs
    adapter/
      behaviour.ex
      req.ex             # built-in adapter
    fs/
      ownership.ex       # respects hearth:owned / hearth:collaborating
test/
  hearth_test.exs
  mix/tasks/hearth/      # one *_test.exs per task
  fixtures/specs/        # OpenAPI fixtures: stripe, petstore, …
  generated/             # golden-file snapshots
```

Spec parsing leans on `yaml_elixir` + `jason`. We do not depend on
`open_api_spex` — its scope is request validation, not codegen, and we want a
clean dependency footprint.

File-writing and config patching are delegated to Igniter — we do not maintain
our own diff/patch logic. The ownership tokens (`hearth:owned`,
`hearth:collaborating`) sit as a preflight check on top of `Igniter.create_or_update_file/4`
and `Igniter.Project.Module.create_module/4`.

---

## Working in this repo

- **TDD throughout.** Tests for Mix tasks use `Igniter.Test` — `test_project/1`,
  `assert_creates/3`, `assert_has_patch/3`, `assert_unchanged/1`,
  `apply_igniter!/1`. Spec-driven generator tests are golden-file: regenerated
  output compared against `test/generated/<case>/expected.ex`. Hand-curate the
  golden files; CI fails if regenerated output drifts.
- **Idempotency is a property test.** Every task must satisfy: `compose_task |>
  apply_igniter! |> compose_task |> assert_unchanged`. Re-running a task on its
  own output is a no-op.
- **Tiny well-named modules.** The renderer-per-layer split is deliberate. If
  `render/layer3.ex` grows past 300 lines, split by concern (params, body,
  auth) before adding another feature.
- **Public API discipline.** Only `Mix.Tasks.Hearth.Install`,
  `Mix.Tasks.Hearth.Gen`, and `Hearth.Adapter.Behaviour` are public. Everything
  under `lib/hearth/spec/` and `lib/hearth/render/` is `@moduledoc false`.
- **Hex docs are the front door.** Every public function gets `@doc` with a
  worked example. The README's first 30 lines must be enough to decide whether
  to install Hearth.

### Step-by-step build log

We are building the library incrementally. Each step lands as a single
commit. Past steps are condensed to current state and load-bearing
contracts; the blow-by-blow lives in git history. Plan for Step 4 lives
at `~/.claude/plans/um-what-s-gitkeep-compiled-hennessy.md`.

#### Done

- **Steps 1–3 — `mix hearth.install`.** Idempotent installer. Adds
  `:hearth` to the consumer's `.formatter.exs` `import_deps`, initializes
  `config :otp_app, hearth_domains: []` in `config/config.exs` (preserving
  any existing value — explicit `false` opt-outs and populated lists
  survive re-runs untouched), and emits a context-aware summary notice
  with three branches: first install (full explainer + `:hearth_domains`
  worked example using the consumer's actual app name), repeat with
  changes (short header + modified-files line), repeat no-op (single
  line). Version stamp via `Application.spec(:hearth, :vsn)`. Touched
  files computed by `Igniter.has_changes?/2` scoped per path.

- **Step 4a — `mix hearth.gen` skeleton + source discrimination.** Task
  with the same optional-Igniter dance as `hearth.install`.
  `Hearth.Spec.Source.resolve/1` (pure) classifies argv as
  `{:url, _} | {:file, _} | {:registry, _} | {:error, _}`. The registry
  regex allows `@` and `.` so `stripe@latest` and `stripe@2024-01-01`
  classify correctly; input is case-folded. The task dispatches per
  shape; missing source, unclassifiable input, missing files, and
  refused install all halt via `Igniter.add_issue/2`. File existence
  is checked via `Igniter.exists?/2` (works against both real fs and
  Igniter's in-memory Rewrite — tests use `test_project(files: %{...})`).

  Auto-composes `mix hearth.install` via speculative `compose_task` +
  `Igniter.has_changes?/2` against `.formatter.exs` and
  `config/config.exs`: discards the composed result if install would
  be a no-op (so consumers don't see "already installed" chatter under
  gen); otherwise `--yes` or `igniter.assigns[:test_mode?]` auto-accept,
  else `Mix.shell().yes?/1` prompts. **This gated-compose pattern is
  the contract for every future Hearth task that needs install state.**

- **Step 4b — Curated, versioned registry.** `Hearth.Registry` ships one
  entry: Stripe, with 14 dated canonical versions covering basil
  (v1712–v2017), clover (v2092–v2203), dahlia (v2248–v2266), plus a
  floating `latest` pointing at `master/openapi/spec3.yaml`. Codename
  aliases (`basil`, `clover`, `dahlia`) resolve to the most-recent dated
  release in their family; date-alone aliases resolve to the
  corresponding `<date>.<codename>`. URLs source from a bare clone of
  stripe/openapi grouped by `info.version`. Pre-2025 codenames are
  intentionally skipped.

  Lookup returns
  `{:ok, %{name, version, resolved_version, url, integration}}` (with
  `integration` derived via `Macro.camelize/1` — `stripe → Stripe`,
  `google_docs → GoogleDocs`), or
  `{:error, {:unknown_name, _}}`, or
  `{:error, {:unknown_version, name, version, available}}`. The gen
  task pattern-matches the tag and emits a distinct user message per
  error path. The gen notice's `(alias for stripe@2025-08-27.basil)`
  annotation is how users discover what an alias resolves to.

  `versions/1` and the unknown-version error filter to canonical
  (URL-backed) entries only. Aliases resolve at lookup time but are
  invisible to listings.

  `mix hearth.gen --list` (no source) prints shortcut names only.
  `mix hearth.gen <name> --list` prints canonical versions for that
  shortcut (the `@version` part is ignored, so `stripe`,
  `stripe@latest`, and `stripe@anything-else` produce identical
  output). `mix hearth.gen <file> --list` prints the file's
  tag-discovery listing (see step 5b). A URL source under `--list`
  errors (the fetcher is not wired). Sets
  `igniter.assigns[:quiet_on_no_changes?]` so query-mode commands
  don't print "No proposed content changes!". Output goes through
  `Mix.shell().info/1`, not notices, so it appears immediately rather
  than under a `Notices:` header.

- **Step 4c — Spec loader for YAML and JSON.** `Hearth.Spec.Loader`
  with two functions: `sniff/1` (extension → `:yaml | :json | :unknown`,
  strips URL query strings) and `decode/2` (bytes + format →
  `{:ok, map} | {:error, term}`). YAML via `YamlElixir.read_from_string/1`;
  JSON via the stdlib `JSON.decode/1` (Erlang 27's `:json` wrapped in
  Elixir 1.18+ — no Jason dep). The mix.exs elixir constraint was
  bumped from `~> 1.15` to `~> 1.18` to access `JSON`.

  Wired into the gen task's `:file` branch. The flow: sniff format
  (unsupported → halt with supported-extensions hint), check existence
  via `Igniter.exists?/2`, pull bytes into Rewrite via
  `Igniter.include_existing_file/2`, decode, summarize. The notice now
  reads `Spec loaded from <path>` with title / info.version / OpenAPI
  spec version / path count / operation count. Decode failures surface
  the parser's message verbatim.

  Test fixtures: OAI's canonical petstore example for OAS 3.0
  (`test/fixtures/specs/petstore-3.0.{yaml,json}`) and tictactoe for
  OAS 3.1 (`tictactoe-3.1.{yaml,json}`). Vendored from
  `OAI/learn.openapis.org` so renderer work in step 5+ has realistic
  `components.schemas` to traverse. The fixtures are read at compile
  time into module attributes and threaded through
  `test_project(files: %{...})` because in test mode `Igniter.exists?/2`
  only consults the virtual fs, never real disk.

  Spec validation was considered (in-house structural checks vs
  `ex_json_schema`) and deliberately deferred to step 5+, where the
  renderer's actual demands codify what "valid enough" means for
  Hearth's purposes.

#### Load-bearing contracts

These were learned the hard way and must hold for future steps:

- **Every commit produces visibly different behavior for distinct user
  inputs.** Skeletons that no-op identically on every input are
  misleading and got reworked.
- **Consumer-facing notices never reference internal CLAUDE.md or step
  numbers.** A test in `gen_test.exs:"consumer-facing docs"` enforces
  this.
- **`long_doc` only advertises features that work today.** Lock-in tests
  refute stale wording and copy-paste traps (e.g. literal
  `mix hearth.gen <name>` outside the `--list` context).
- **Tasks that need install state open with the same gated compose
  pattern** described under Step 4a.

- **Step 5a — Operation extraction + tag filter.** Two pure modules,
  no I/O, no codegen. `Hearth.Spec.Operation` flattens a decoded spec's
  `paths → <path> → <method>` nesting into `%Operation{}` structs;
  `extract/1` builds the list, `tag_index/1` groups by tag for the
  step-5b discovery listing. The `:id` field is the snake_case function
  name — always present, derived from `operationId` (via a `sanitize/1`
  that runs `Macro.underscore` then collapses any non-alphanumeric run,
  so hyphenated ids like `get-board` become `get_board`) or from
  `<verb>_<path-slug>` when `operationId` is absent. Collisions get
  numeric suffixes (`get_user`, `get_user_2`) — an explicit test pins
  this so a future override mechanism has a fixed point. Path-item-level
  `parameters` merge into each operation. `$ref` parameters are left
  unclassified (no `"in"` key) — resolution is step 6+.

  `Hearth.Spec.Filter` parses the repeatable `--tag` flag — `parse/1`
  takes the list of `--tag` values; within a value the first `:`
  separates the tag name from a comma-separated operationId allowlist
  (`"Subscriptions:create,list"`), a value with no colon is a whole
  tag. Tag names may contain commas/semicolons/spaces. User-supplied
  operationIds are run through `Operation.sanitize_id/1` so an id
  copied straight from the spec (`getBoard`, `get-board`) still
  matches the derived `:id`. A stray `:` in the operationId portion is
  a rejected typo — but an id portion that is *only* delimiters
  (`"Customers::"`) reports "no operationIds" instead. Repeated tags
  merge (union + sort their `:only` lists). `apply/2` selects matching
  operations (union semantics across rules).

- **Step 5b — Tag discovery + operation-count gate.** `mix hearth.gen`
  now extracts operations from a decoded file source and selects a
  subset. New flags: `--tag` (`:keep` — repeatable) and
  `--n-operations` (integer, default 25). The gen task's `:file` branch
  calls `Operation.extract/1`, then:
  - ≥1 `--tag` → `Filter.parse/1` + `Filter.apply/2`; a parse error
    halts with the bad-syntax message.
  - no `--tag` → operation-count gate: at or under `--n-operations`,
    proceed with everything; over it, **halt** with the tag-discovery
    text (built by the shared `tag_discovery/2`).

  The tag-discovery text — also produced by `mix hearth.gen <file>
  --list` — has three parts: a per-tag operationId listing
  (`"Tag": [:op_id, …]`), a **fully-expanded subset command** (the real
  invocation with every tag spelled out as `--tag "Tag:op1,op2,…"`, one
  per backslash-continued line — the user copies it and deletes whole
  lines or individual operationIds, no lookup or guessed intent), and
  the generate-everything escape hatch (`--n-operations <count>`). The
  command echoes the actual source path and `--integration` value when
  they were given.

  The success notice reports `Selected N of TOTAL operations across M
  tags`. Igniter aggregates a `:keep` option into one list and defaults
  an absent one to `[]`, so the task reads `options[:tag]` directly
  (not `Keyword.get_values`).

- **Step 5c — Layer 2 behaviour renderer.** `mix hearth.gen <file>
  --integration <Name>` now writes a behaviour module to disk — the
  first step that generates code. `--integration` is required for file
  sources (a missing one halts with a helpful issue).

  - `Hearth.Render.ModuleNames.layer2/1` derives the module name.
    Verbose style: `<App>.<Domain>.<Integration>.<Integration>Api`,
    where the domain segment defaults to `Integrations`, `--domain`
    overrides it wholesale, and `--no-domain` drops it. `--style`
    remains unwired.
  - `Hearth.Render.Layer2.render/3` builds the behaviour source — one
    `@callback` per selected operation. Path params become positional
    `String.t()` args (named via `Operation.sanitize_id/1`), query/body
    funnel through a final `opts :: keyword()`, every callback returns
    the generic `{:ok, Req.Response.t()} | {:error, Exception.t()}`.
    An operation's `summary` and `description` become a `@doc` heredoc
    on the callback — summary on the first line, description below it
    (blank line between); either may be absent, and with neither no
    `@doc` is emitted. The module is assembled as a string and run
    through `Code.format_string!/1` — it normalizes layout and raises
    on any syntax error.
  - **Moduledoc metadata footer.** `render/3`'s third argument is a
    metadata map (`:source`, `:title`, `:version`, `:openapi`,
    `:description`); the gen task fills it via `spec_metadata/2` from
    the source path and the spec's `info` block. The moduledoc closes
    with a `## Source` section — a markdown bullet list of the
    populated fields, plus the spec `description` below it. Absent
    fields are skipped; with no metadata at all (the `\\ %{}` default,
    used by unit tests) the section is omitted entirely.
  - The gen task writes via `Igniter.create_new_file/4` with
    `on_exists: :overwrite` (re-running regenerates silently — ownership
    tokens are step 6+). The path comes from
    `Igniter.Project.Module.proper_location/2`.

  Renderers build source as strings, not quoted AST — typespec-heavy
  output (`@callback ... :: ...`) is clearer to assemble as text, and
  `Code.format_string!/1` is the syntax check.

- **Step 5d — Layer 1 raw Req client.** `mix hearth.gen` now writes
  two files per run — Layer 1 (`<App>.Integrations.<Integration>`,
  no `Api` suffix) alongside Layer 2.

  - `Hearth.Spec.Auth.strategy/1` reduces a spec's
    `components.securitySchemes` + top-level `security` to one strategy:
    `:none | :bearer | {:api_key, :header|:query, name} | {:unsupported,
    type}`. The primary scheme is the one named by `security`, else the
    first by name order. Bearer + API-key are fully rendered;
    oauth2 / openIdConnect / http-basic become `{:unsupported, _}`.
  - `Hearth.Render.Layer1.render/4` builds the raw client: a `@base_url`
    from the spec's first `servers` entry (a missing one leaves a TODO
    + placeholder), `@otp_app`, and a `new/1` (mirroring `Req.new/1`)
    returning a configured `%Req.Request{}`. Bearer → `auth: {:bearer,
    …}`; API-key → header or query param; `:none` → base URL only;
    `{:unsupported, _}` → base URL only plus a TODO comment.
    Bearer/API-key also get a `credential/1` that reads
    `Application.get_env(@otp_app, __MODULE__)[:api_key]` with an
    `:api_key` opt override, raising a clear error if absent.
  - **Credential model (confirmed with Kaspar):** the credential lives
    in app config keyed by the Layer 1 module — `config :otp_app,
    <ClientModule>, api_key: …`. Step 5f generates the entry in
    `config/runtime.exs`: prod path does `System.get_env("X") || raise`,
    and inside an `if config_env() == :dev` block a dev path falls back
    to a `"DEV_NO_X"` placeholder. That config also later holds the
    Layer 3 impl module. Layer 1 here only *reads* the config.

  **Deferred refinements** (TODO comment parked in `Hearth.Spec.Auth`):
  - *Multiple `servers`.* Resolved — see "Step 5i" below.
  - *Multiple auth schemes.* v1 auto-picks the primary. Planned:
    `mix hearth.gen` prompts the user to choose; a `--auth-scheme
    <name>` flag selects non-interactively; under `--yes` with several
    schemes and no `--auth-scheme`, the task halts rather than guesses.

- **Step 5e — Layer 3 Req implementation.** `mix hearth.gen <file>
  --integration <Name>` now writes the third file — the Req-based
  implementation that satisfies the Layer 2 behaviour. After 5e the
  integration is functional end to end.

  - Module: `<Layer2>.Req` (`ModuleNames.layer3/1`). `Hearth.Render.Layer3`
    `@behaviour`s Layer 2, `alias`es Layer 1, and renders one `@impl
    true` function per operation.
  - **API shape (post-redesign).** Layer 1 owns all HTTP machinery and
    exposes three functions: `new/1` (builds the configured `%Req.Request{}`,
    mirroring `Req.new/1`), `request/2` and `request!/2`:

    ```elixir
    def request(url, opts \\ []), do: Req.request(new(url: url), opts)
    def request!(url, opts \\ []), do: Req.request!(new(url: url), opts)
    ```

    `new/1` ends with `|> Req.merge(opts)` so caller opts (e.g.
    `new(url: …)`) flow into the request — the Hearth-only `:api_key`
    override is `Keyword.delete`d before the merge for auth schemes
    that read it. Each Layer 3 function delegates to `<Layer1>.request/2`
    — never `new/1` or `Req` directly. `Req.request/2`'s return type
    already matches the Layer 2 callback spec.
  - Path params interpolate into the URL (`{petId}` → `#{pet_id}`).
    `:get` is Req's default method, so GET operations call
    `<Layer1>.request(url, opts)` with no `method:`; any other verb
    prepends `[method: …] ++ opts`. Query/body params ride through
    `opts` untouched — every function body is uniform plumbing.
  - **Empty-selection guard:** a `--tag` filter matching no operations
    now halts (`"no operations matched the --tag filter"`) instead of
    generating empty modules.
  - **`req` dependency:** the generated Layer 1/3 reference `Req` at
    runtime. `req` reaches Hearth only transitively via the optional,
    dev-time `igniter` dep, so the *consuming* app needs it directly.
    `mix hearth.gen` adds `{:req, "~> 0.5"}` via
    `Igniter.Project.Deps.add_dep/2` — placed in the gen task, not
    `hearth.install`, because the generated code is what needs it
    (install alone produces nothing that does).
  - **Shared base path folding.** `Hearth.Spec.BasePath.common_prefix/1`
    finds the longest leading path-segment sequence shared by every
    operation in the spec (`/api/v1/customers`, `/api/v1/subscriptions`
    → `/api/v1`); the gen task `BasePath.strip/2`s it off the selected
    operation paths, so Layer 3 calls read `request("/customers", opts)`
    not `request("/api/v1/customers", opts)`. The prefix is always
    stripped and is threaded into `Layer1.render/5` as a `path_prefix`
    argument: Layer 1 appends it to the spec's base URL **or**, when the
    spec declares no `servers`, to the `https://api.example.com`
    placeholder (`@base_url "https://api.example.com/v3"` + the
    set-the-base-URL TODO) — so the prefix is never lost. The prefix is
    capped one segment short of the shortest path (every operation keeps
    a segment) and is computed over *all* extracted operations, not the
    `--tag`-selected subset, so it stays stable regardless of filtering.

- **Step 5g — Layer 1 auth test generation.** `mix hearth.gen` now
  writes a **fourth file** — `test/<app>/integrations/<name>_test.exs` —
  a `Req.Test`-plug ExUnit module that exercises the generated raw
  client and asserts the auth scheme attaches the right credential at
  request time. Every integration ships with a runnable auth guarantee.

  - `Hearth.Render.Tests.layer1/4` renders the test, branching on the
    `Hearth.Spec.Auth.strategy/1` value: bearer → asserts the
    `authorization: Bearer …` header; api-key header/query → asserts the
    header (downcased) or query param; `:none` → asserts no auth header;
    `{:unsupported, _}` → a smoke test plus a TODO. Bearer/api-key tests
    seed the credential with `Application.put_env` in `setup` — needed
    because `request!/2` does not thread caller opts into `new/1` — so
    the file is `async: false`.
  - `ModuleNames.layer1_test/1` derives the test module as a *sibling*
    of Layer 1 with a `Test` suffix (`App.Integrations.StripeTest`); the
    suffix routes it to `test/` via
    `Igniter.Project.Module.proper_location/3` with `:test`. The gen
    task's `sources` tuples now carry a location kind (`:source_folder`
    / `:test`).
  - **No `plug` dependency is added.** `Req.Test` needs Plug, but `req`
    already declares `plug` as an *optional all-environment* dependency
    — a consumer dep scoped `only: :test` diverges from that and breaks
    the build. Instead the generated test file wraps its module in
    `if Code.ensure_loaded?(Plug.Conn) do … end`: the file always
    compiles, the test activates when `plug` is present (a Phoenix app
    already has it; otherwise the consumer adds `{:plug, "~> 1.0"}` —
    all envs, per its header comment). The gen task still adds
    `{:req, "~> 0.5"}` (`on_exists: :skip`).
  - Hearth's own `mix.exs` declares `req` and `plug` as `optional: true`
    — for clarity (they document what generated code needs) and so
    Hearth's dev smoke-tests can compile and run generated code. The
    renderer is verified by string/golden tests like the other
    renderers; Hearth does not compile-and-run generated code in its
    own suite.

- **Step 5f — host wiring (dispatcher, Mox mock, config).** A
  generated integration is now usable by the host app end to end.

  - **Layer 2 is no longer a pure behaviour.** `Hearth.Render.Layer2`
    emits, per operation, the `@callback` *and* a delegating `def`
    (`def list_pets(opts \\ []), do: impl().list_pets(opts)`), plus an
    `@otp_app` attribute and `defp impl, do:
    Application.get_env(@otp_app, __MODULE__, [])[:impl] ||
    __MODULE__.Req`. Business logic calls the `def` directly; the
    default impl is Layer 3, so prod/dev need no config. `render/3`'s
    third arg became an `opts` keyword (`:metadata`, `:otp_app`).
  - **`Hearth.Render.Mocks`** renders `test/support/mocks.ex` — a flat
    list of `Mox.defmock(<Mock>, for: <Layer2>)` lines. `mix hearth.gen`
    adds `{:mox, "~> 1.0", only: [:test]}` to the consumer (`on_exists:
    :skip`); `mox` is not an optional dependency of anything Hearth
    pulls in, so `only: :test` is safe — unlike `plug`, it cannot
    diverge. `ModuleNames.mock/1` → `<Layer2>.Mock`.
  - **Config patches** (`hearth.gen`'s `wire_mock` / `patch_*`): the
    credential goes to `config/runtime.exs` via `configure_runtime_env`
    — prod `System.get_env("<INT>_API_KEY") || raise`, dev a
    `"DEV_NO_…"` fallback — keyed by the Layer 1 module; skipped for
    `:none` / `:unsupported` auth. `config/test.exs` gets
    `impl: <Mock>`. `config/config.exs` `:hearth_domains` gains the
    Layer 2 module via `Igniter.Code.List.append_new_to_list` — which
    returns `:error` for a non-list, so a `false` opt-out is left
    untouched, and is idempotent on re-run. `test/support/mocks.ex` is
    appended idempotently (string-contains check on the mock name).
  - `mix hearth.gen` is fully idempotent: re-running adds no duplicate
    `defmock` or `:hearth_domains` entry, and `updater: &{:ok, &1}`
    preserves existing credential/impl config.

- **Step 5h — external integration test.** `mix hearth.gen` now writes
  a **fifth file** — `test/<app>/integrations/<name>_external_test.exs`
  — a scaffold of real HTTP calls against the live API for introspecting
  the integration and validating use-cases.

  - `Hearth.Render.Tests.external/6` renders an `@moduletag :external`
    ExUnit module with one `test` per operation. Each calls **Layer 3
    directly** (`<Layer2>.Req.<op>`) — not Layer 2, whose dispatcher
    routes to the Mox mock in `:test`. Path params become `"TODO"`
    placeholder args; every test has a `# TODO` and a baseline
    `assert {:ok, %Req.Response{}} = …`. Credentialed auth gets a
    `setup` seeding the key from `<INT>_API_KEY` (`:test` env has no
    credential — `config/runtime.exs` only sets it for prod/dev) →
    `async: false`; `:none`/`:unsupported` → no setup, `async: true`.
    `ModuleNames.external_test/1` → `<Integration>ExternalTest`.
  - **Ownership: user-owned scaffold.** Unlike the other four files
    (`:overwrite`), the external test is written with `on_exists:
    :skip` — generated once, never overwritten, the user carries on
    from it. The `sources` tuple grew a per-file `on_exists` element.
  - `patch_test_helper/1` adds `ExUnit.configure(exclude: [:external])`
    to `test/test_helper.exs` (idempotent) — `:external` tests are
    opt-in: `mix test` skips them, `mix test --include external` runs
    them.

- **Step 5i — multi-server base-URL resolution.** A spec's `servers:`
  list is now resolved properly (was: first server only).

  - `Hearth.Spec.Servers` (pure) classifies each server URL — *non-prod*
    if it contains `dev.`/`staging.`/`preview.`/`demo.`/`sandbox.` or
    its host TLD is `.dev`, else a *prod-candidate*. `resolve/1` returns
    the **default** URL (Layer 1's `@base_url` — a prod candidate, or
    the first of several), the **test** URL (a non-prod server, written
    to `config/test.exs` so the external test points off production),
    each one's commented-override `alternates`, a `warn?` (0 servers),
    and `fallback_default?` (every server non-prod).
  - **Layer 1's base URL is config-overridable.** `new/1` reads
    `base_url()` — `Application.get_env(@otp_app, __MODULE__)[:base_url]
    || @base_url` — exactly like `:api_key`. `@base_url` stays the
    spec-derived compile-time default (with the BasePath prefix folded
    in).
  - The gen task: `patch_base_url_config` writes `config/test.exs`
    `base_url:` (prefix folded in to match `@base_url`);
    `patch_base_url_alternates` appends a commented-out override block
    (prod alternates → `config/config.exs`, non-prod → `config/test.exs`,
    idempotent per-integration marker); `warn_servers` emits an
    `Igniter.add_warning` for 0 servers and a notice for the
    all-non-prod fallback.

- **Step 5j — pruned spec artifact.** `mix hearth.gen` now writes a
  sixth file: `priv/hearth/<integration>.yaml` — the input spec pruned
  to exactly the selected operations, the integration's versioned
  source of truth (and a stable artifact for ownership-token regen to
  diff against).

  - `Hearth.Spec.Prune.prune/2` (pure, raw-map) keeps `info`/`servers`/
    `security`/extensions untouched, filters `paths` to the selected
    operations (path-item-level keys ride along), and filters
    `components` to only the entries transitively reachable by `$ref`
    from the kept paths — a reachability walk through
    `allOf`/`anyOf`/`oneOf`, `items`, nested properties; **not** `$ref`
    resolution/inlining. `securitySchemes` is kept whole. (TED + only
    `search`: 11 paths → 1, 29 schemas → 13.)
  - `Prune.to_yaml/1` encodes the result (`ymlr` — `yaml_elixir` only
    reads), emitting the top-level keys in conventional order
    (`openapi` → `info` → … → `paths` → `components`) by encoding each
    key separately, since `ymlr` otherwise iterates a map in term
    order. `on_exists: :overwrite` — re-derived each run.
  - **`open_api_spex` was evaluated and rejected.** It has no
    spec-pruning, and its decoder (`OpenApiSpex.OpenApi.from_map/1`)
    *raises* on the OAS 3.1 fixture — so it cannot be Hearth's parser
    or validator without dropping 3.1 support. The CLAUDE.md non-goal
    stands; the prune works on raw maps.

- **Step 6 — `mix hearth.gen` is create-only.** `gen` no longer
  overwrites an existing integration. Before writing anything,
  `write_layers/6` resolves the Layer 1 module's
  `proper_location/3` and, if `Igniter.exists?/2` finds it, halts via
  `Igniter.add_issue/2` ("`<Layer1>` already exists … `hearth.gen`
  only creates"). On a fresh project the flow is unchanged — the body
  past the preflight moved into `render_layers/7`.

  Layer 1's file is the existence marker: if it is present the
  integration is already generated. This makes a re-run of `gen` a
  safe no-op-with-issue rather than a silent overwrite — the
  "dangerous action" the owner flagged. Regenerating from an updated
  spec is a future `mix hearth.regen` (ownership-token-aware); the
  three `gen` re-run idempotency tests were removed, as `gen` re-runs
  now halt — that idempotency property moves to `regen`.

#### Pending

- **Steps 4d–4f (deferred, parallel track)** — `Hearth.Spec.Cache`,
  `Hearth.Spec.Fetcher` (Req + cache; bundles the `latest`-resolution
  enhancement — TODO parked on the `latest` entry in
  `lib/hearth/registry.ex`), end-to-end URL/registry codegen. These
  light up URL and registry sources; file-source codegen (step 5)
  doesn't depend on them.

---

## Commit conventions

Follow Conventional Commits.

```
feat: support OpenAPI 3.1 webhooks
fix: dedupe config patches when --integration is rerun
refactor: extract auth strategy from layer1 replayer
docs: worked example for OAuth2 TODO
test: golden file for petstore spec
```

PRs that change generator output must include the regenerated golden files in
the same commit.
