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

* creating lib/app/billing/integrations/stripe.ex
* creating lib/app/billing/integrations/stripe/stripe_api.ex
* creating lib/app/billing/integrations/stripe/stripe_api/req.ex
* creating test/app/billing/integrations/stripe/stripe_api_test.exs
* patching test/support/mocks.ex            (+1 line)
* patching config/config.exs                (+3 lines)
* patching config/test.exs                  (+2 lines)

  4 files created · 3 files patched · 0 skipped

Next steps:
  • set STRIPE_API_KEY in your environment
  • run `mix test test/app/billing/integrations/stripe/stripe_api_test.exs`
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

```
# Without --domain
App.Integrations.Stripe                  # Layer 1
App.Integrations.Stripe.StripeApi        # Layer 2
App.Integrations.Stripe.StripeApi.Req    # Layer 3
App.Integrations.Stripe.StripeApi.Mock   # Mox mock

# With --domain Billing
App.Billing.Integrations.Stripe.StripeApi
# ...same shape, deeper namespace

# With --domain Billing --no-integrations-segment
App.Billing.Stripe.StripeApi
# drops the .Integrations segment for users who prefer flatter trees
```

Other styles available via `--style`:

```
--style tight    # App.…Stripe.Api / .Api.Req       (less repetitive)
--style split    # App.…Stripe.Client / .Api / …    (explicit Client suffix)
```

The integration name (`Stripe`) is required. The domain (`Billing`) is
optional. The OTP app name is auto-detected from `mix.exs`.

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
- [ ] **Verbose module style** as default. `--style {verbose|tight|split}` and
      `--no-integrations-segment` as flags.
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
- [ ] **AsyncAPI input.** Generate websocket / pub-sub clients with the same
      three-layer shape. Sister project, not Hearth itself.
- [ ] **GraphQL SDL input.** Different enough that it probably wants its own
      generator. Listed here only to acknowledge "we thought about it."

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
  output). Non-registry sources with `--list` error. Sets
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

  `Hearth.Spec.Filter` parses the `--tags` CLI string (`;` / `:` / `,`
  three-level delimited) into `[{tag, :all | {:only, ids}}]` and
  `apply/2` selects matching operations (union semantics across rules).

#### Pending

- **Step 5b (next) — Tag discovery + operation-count gate.** Wires 5a
  into the gen task: extract, apply `--tags`, or — past the
  `--n-operations` threshold with no filter — halt with a
  copy-pasteable tag listing. No codegen yet.
- **Step 5c — Layer 2 behaviour renderer.** Writes the behaviour module.
- **Steps 5d–5f** — Layer 1, Layer 3, Mox + config wiring.
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
