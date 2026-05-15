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

We are building the library incrementally. Each step lands as a single commit
and updates this section.

- **Step 1 (done)** — `mix hearth.install` skeleton. Adds `:hearth` to the
  consumer's `.formatter.exs` `import_deps`. Tested with `Igniter.Test`.
- **Step 2 (done)** — `mix hearth.install` initializes `:hearth_domains` to
  `[]` in `config/config.exs` via `Igniter.Project.Config.configure_new/6`.
  Existing values are preserved: an explicit `false` opt-out and a populated
  list both survive re-runs untouched. Four properties covered: file
  creation, `false` preservation, populated-list preservation, full idempotency.
- **Step 3 (done)** — `mix hearth.install` emits a context-aware summary
  notice. Three branches, dispatched on pre-run state and post-run diff:
  - **First install** (`:hearth_domains` was absent): full explainer with
    a Hearth-version header, list of modified files, a worked
    `config :otp_app, hearth_domains: [...]` example using the consumer's
    actual app name, opt-out instructions, and a `mix hearth.gen` pointer
    that names OpenAPI 3.x as the input format.
  - **Repeat install, files changed**: short `=== Hearth vX.Y.Z ===` header
    + `Modified: <files>` line. No re-explanation.
  - **Repeat install, no changes**: single-line `Hearth vX.Y.Z already
    installed — no changes.`

  The version stamp comes from `Application.spec(:hearth, :vsn)`. Touched
  files are computed by `Igniter.has_changes?/2` scoped per path against
  the post-patch igniter. The notice deliberately does **not** reference
  unreleased commands like `mix hearth.regen` — a test enforces this.

  UX feedback items addressed in this step: 7 (file-summary), 8 (notice
  header), 9 (repeat-run noise), 10 (`hearth.regen` reference dropped),
  11 (OpenAPI hint added), 12 (version stamp). Items 1–5 are upstream
  Igniter ergonomics and out of scope here.
### Step 4 — `mix hearth.gen` spec input pipeline

Plan: `~/.claude/plans/um-what-s-gitkeep-compiled-hennessy.md`.

Sliced into micro-steps so each is a single small commit, mirroring the
install cadence. End-state demo for step 4: `mix hearth.gen stripe`
fetches Stripe's spec, caches it under `priv/hearth/cache/`, decodes it,
and prints a summary. Code generation (the renderers) is step 5+.

- **Step 4a (done)** — `mix hearth.gen` task skeleton + source
  discrimination (the original 4a+4b folded together so each commit adds
  observable behavior, not just code). Same optional-igniter dance as
  `hearth.install`. `info/2` declares `positional: [:source]` so a missing
  source raises a useful `ArgumentError` from Igniter rather than silently
  no-op'ing. `Hearth.Spec.Source.resolve/1` (`lib/hearth/spec/source.ex`)
  is a pure function that classifies the argument as `{:url, …}` |
  `{:file, …}` | `{:registry, …}` | `{:error, reason}`. The task dispatches
  on the shape and emits a per-shape notice naming both what was recognized
  and which pipeline stage comes next; unclassifiable inputs go through
  `Igniter.add_issue/2` so the run halts.

  UX guidelines learned the hard way during this step: every commit must
  produce visibly different behavior for distinct user inputs. The notice
  is consumer-facing, so it never references our internal CLAUDE.md —
  a test (`gen_test.exs:"consumer-facing docs"`) enforces this. The
  long_doc only advertises features that actually work today; registry
  shortcuts are described as "not yet wired" until step 4c.
- **Step 4a-followup (done)** — Three UX polish items landed together
  because they shape the contract for every future Hearth task:

  1. **Gated install composition.** `mix hearth.gen` speculatively composes
     `mix hearth.install` and uses `Igniter.has_changes?/2` against
     `[".formatter.exs", "config/config.exs"]` to decide whether install
     would actually do work. If not — discard the composed result and use
     the original igniter, so consumers never see install's "already
     installed" notice as gen-precondition chatter. If install IS needed:
     `--yes` or `igniter.assigns[:test_mode?]` auto-accept; otherwise
     `Mix.shell().yes?/1` prompts the user. Refusal halts with a clear
     `Igniter.add_issue/2` message pointing at `--yes` or manual install.
  2. **File-existence validation.** `:file` sources are checked via
     `Igniter.exists?/2` (which checks both the real filesystem AND
     Igniter's in-memory Rewrite state, so tests can use
     `test_project(files: %{...})`). Missing files halt with an issue
     naming the path; no misleading "Source recognized: file" notice.
  3. **`mix help` honesty.** `mix help hearth.gen` now has a full Options
     section documenting every flag, and the registry example is reframed
     as "Coming soon — no registry names are resolvable today" rather
     than `mix hearth.gen <name>` (a copy-paste trap). `mix help
     hearth.install` cross-links to the gen auto-invocation so users
     reach the same understanding from either direction. Two tests
     (`long_doc documents every task option`, `long_doc no longer shows
     a copy-pasteable registry example that does not work`) guard against
     regression.

  This composition pattern is the contract for every future Hearth task
  that needs install state — they all open with the same gated compose.

- **Step 4b (done)** — `Hearth.Registry`: curated, versioned shorthand
  map wired into the gen task.

  **Shape.** `@entries` is `%{name => %{version => url}}`. Each shortcut
  MUST have a `"latest"` key; bare `stripe` is shorthand for `stripe@latest`.
  Version strings are free-form (ISO-like dates or vendor tags) and sort
  with `"latest"` pinned to the front. v1 ships one entry — Stripe,
  `https://raw.githubusercontent.com/stripe/openapi/refs/heads/master/latest/openapi.spec3.json`
  (HTTP 200 verified, etag present). Historic spec URLs land as Kaspar
  confirms them.

  **Integration name derivation.** No `:integration` field stored — derive
  via `Macro.camelize/1`: `stripe → Stripe`, `google_docs → GoogleDocs`,
  `aws_s3 → AwsS3`. `--integration <Name>` still overrides per-call.

  **Lookup return shape.** `{:ok, entry}` |
  `{:error, {:unknown_name, name}}` |
  `{:error, {:unknown_version, name, version, available}}`. Three error
  paths get three distinct user messages — the gen task pattern-matches
  on the tag and emits a different issue for "no such shortcut" vs.
  "shortcut exists, this version doesn't."

  **Source.resolve change.** Registry pattern widened to allow `@` and
  `.` (`^[a-zA-Z0-9][a-zA-Z0-9_@.\-]*$`), so `stripe@latest` and
  `stripe@2024-01-01` classify as `:registry` rather than falling
  through to `:error`. Must still start with alphanumeric.

  **Tests.** Eight registry tests (bare→latest equivalence, unknown
  name vs unknown version paths, `Macro.camelize` documentation tests
  covering `google_docs` / `aws_s3`, case-sensitivity contract, sorted
  `list/0`, `versions/1`). Four new source tests for `@version`
  syntax. Three new gen tests for the bare/explicit equivalence,
  unknown-version dispatch, and the case-folded shorthand.
- **Step 4c (next)** — `Hearth.Spec.Loader.decode/2`: bytes + content-type → map.
  Adds `yaml_elixir` and `jason` deps. Wire it so `mix hearth.gen ./local.yaml`
  reports decode results instead of "decode not yet wired."
- **Step 4d** — `Hearth.Spec.Cache`: on-disk read/write of
  `priv/hearth/cache/<sha256>/spec.{ext}` + `meta.exs`.
- **Step 4e** — `Hearth.Spec.Fetcher`: Req-based HTTP with cache. First
  step that does network I/O. Tests use `Req.Test` stubs. Wire so URL +
  registry sources actually fetch.
- **Step 4f** — End-to-end summary: `mix hearth.gen stripe` prints
  "Loaded N paths from Stripe API." Manual smoke from a sample consumer.

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
