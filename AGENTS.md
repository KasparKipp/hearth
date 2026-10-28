# Hearth

**Generate small, Req-based API clients from API specs.**

Hearth is a set of [Igniter](https://hexdocs.pm/igniter) Mix tasks that turn
an OpenAPI 3 or Swagger 2.0 spec into a **small development kit**: plain
Elixir files the user owns, built on [Req](https://hexdocs.pm/req), covering
only the operations they pick.

Three documents, three readers:

- **`README.md`**: the front door. What Hearth is, what it generates, how
  to install and run it, and the examples. Start there; this file doesn't
  repeat it.
- **`usage-rules.md`**: the full consumer guide, for people and for coding
  agents working in a project that uses Hearth.
- **This file**: the contributor's context. How Hearth is built, what works
  today in detail, the contracts every change keeps, and what comes later.
  History lives in git.

---

## The mental model

Every integration is the **three-layer HTTP client pattern** (the README's
"What gets generated" has the module table):

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
| `mix hearth.install` | One-time per-project setup (formatter import).                              |
| `mix hearth.gen`     | Generate the three-layer integration from an API spec. Create-only.         |
| `mix hearth.regen`   | Regenerate integrations from their pruned specs, ownership-aware.           |
| `mix hearth.diff`    | Report drift between integrations and their sources. Read-only, CI-friendly. |

---

## Module layout

`<App>.<Domain>.<Integration>` plus per-layer suffixes, in the **verbose**
style: Layer 2 repeats the integration name (`StripeApi`), so a grep for it
hits every call site without false positives from other `.Api` modules. The
domain defaults to `Integrations`; `--domain` replaces it and `--no-domain`
drops it (usage-rules.md has the flags).

```
App.Integrations.Stripe                  # Layer 1
App.Integrations.Stripe.StripeApi        # Layer 2
App.Integrations.Stripe.StripeApi.Req    # Layer 3
App.Integrations.Stripe.StripeApi.Mock   # Mox mock
App.Integrations.StripeTest              # Layer 1 auth test (test/)
App.Integrations.StripeExternalTest      # live-API scaffold (test/)
```

Every layer derives from the Layer 1 module alone
(`Hearth.Render.ModuleNames.from_layer1/1`) — that is how `regen` needs only
the Layer 1 name. The OTP app name is auto-detected from `mix.exs`.

---

## Ownership model

`gen` only creates; `regen` overwrites generated files by default. That's
intentional: specs change in ways we can't three-way merge, and most
generated files are plumbing. The opt-outs are moduledoc tokens,
`hearth:owned` (skipped) and `hearth:collaborating` (y/N per file; `--yes` /
test mode accept), documented for users in usage-rules.md. What the code
keeps:

- Only `@moduledoc` text is scanned (`Ownership.classify/1` parses the file),
  so a token copied into a Layer 2 `@doc` from a spec description, or
  mentioned in a comment, doesn't count. A file that doesn't parse falls
  back to a whole-file scan, erring toward owned.
- The external test is a user-owned **scaffold**: created once, never
  overwritten. `regen` only offers to add to it: tests for new operations,
  setup for new values.
- A file whose token can't be read is skipped, never overwritten (fail
  closed).

---

## Status

The README's Status section is the public summary; **Current state** below
has the detail. v1's scope is done except `--style`, now on the v2 list.

---

## v2 — close-to-shore roadmap

- [x] **Custom function naming.** Shipped as `.hearth.exs`
      `overrides: [operation_ids:]` (see **Overrides**).
- [ ] **Response typespecs from schemas.** Generate `@type list_entities_response :: %{…}`
      from `responses.<code>.content.application/json.schema`. Bumps Hearth from
      "generator" toward "client framework."
- [ ] **OAuth2 client credentials.** Auto-generate a token-refresh request step
      when `securitySchemes` declares `oauth2 + clientCredentials`. Today a
      resolver fetches the token (`auth: [credential: [resolve: …]]`), as the
      OHIP example does.
- [x] **Multiple auth schemes.** Shipped as `.hearth.exs` `auth: [scheme:]`;
      without it gen wires `Auth.default/1` (see **Auth choice**).
- [x] **Swagger 2.0 conversion.** `Spec.Swagger` converts in memory before
      anything else sees the spec.
- [ ] **`--style {verbose|tight|split}`** — designed, not wired:
      `tight` → `…Stripe.Api` / `.Api.Req`; `split` → `…Stripe.Client` / `.Api`.
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
      generated once into the consumer's project (`hearth:owned`, never
      regenerated) to hold user-editable Req request steps that every
      Layer 1's `new/1` appends.

      The problem it solves: custom steps written into Layer 1 are lost on
      the next `regen` unless the user marks the whole file `hearth:owned`,
      which also freezes the generated parts (base URL, auth). A separate,
      seeded module keeps the user's steps out of regenerated code. Layer 1
      already appends a generated step the same way (`put_api_key/1`), so
      the hook pattern is in place.

      ```elixir
      # Layer 1 — generated new/1 gains the shared steps
      def new(opts \\ []) do
        Req.new(base_url: base_url())
        |> Req.Request.register_options([:api_key])
        |> Req.Request.append_request_steps(put_api_key: &put_api_key/1)
        |> MyApp.Hearth.Steps.attach()
        |> Req.merge(opts)
      end

      # MyApp.Hearth.Steps — generated once, hearth:owned, user-editable
      def attach(request) do
        request
        |> Req.Request.append_request_steps(user_agent: &put_user_agent/1)
      end

      defp put_user_agent(request) do
        Req.Request.put_header(request, "user-agent", "my_app/1.0")
      end
      ```

      Candidates to seed it with: retry policy, custom headers, logging and
      telemetry, pagination cursors. (Not "promote a GET with a body to a
      POST" — Req 0.7 does that itself.)
- [x] **Prefixed-ID URL shorthand.** Shipped as `.hearth.exs`
      `prefixed_ids:`, with the prefix → resource mapping named per entry
      (see **Prefixed ids**).
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
    hearth.diff.ex             # pruned spec vs source → drift report (read-only)
  hearth/
    registry.ex                # curated, versioned spec shortcuts (stripe@…), + .hearth.exs ones
    config.ex                  # pure: .hearth.exs — parse, keys, entry fields
    config/
      literal.ex               # pure: the file as data — parsed, never evaluated, literals only
      schema.ex                # pure: the file's shape, one NimbleOptions schema + its errors
      types.ex                 # pure: the schema's custom types (names, value forms, JSON)
      project.ex               # read / write .hearth.exs (Igniter-guarded)
    spec/                      # pure: decoded spec → data
      source.ex                # argv → {:file | :url | :registry | :error, _}
      loader.ex                # sniff format, decode YAML/JSON
      fetcher.ex               # GET a spec over http(s) with OTP :httpc
      operation.ex             # paths → %Operation{}; safe names, path args
      filter.ex                # --tag parsing + selection
      auth.ex                  # securitySchemes → auth strategy
      servers.ex               # servers → default / test base URLs
      base_path.ex             # shared path prefix (stops at templated segments)
      prune.ex                 # spec → pruned spec + YAML encoding
      selection.ex             # the tags / operations gen selected, for .hearth.exs
      swagger.ex               # Swagger 2.0 → OpenAPI 3.0, right after decode
      merge.ex                 # sources: — several specs merged into one
      overrides.ex             # an entry's overrides: applied to the source spec
      patches.ex               # overrides: [patches:] — JSON pointer → value edits
      prefixed_ids.ex          # prefixed_ids: functions, resolved resources
      headers.ex               # required-header suggestions for headers:
      values.ex                # credential: / headers: / base_url: — config, option or resolver
      drift.ex                 # pruned spec vs re-pruned source → changes
      drift/schema.ex          # JSON schema shape changes (additive / breaking)
    render/                    # pure: data → source strings
      module_names.ex          # every layer's module from Layer 1
      layer1.ex  layer2.ex  layer3.ex
      tests.ex                 # Req.Test auth test + :external scaffold
      prefixed_ids.ex          # resource_path/2 + the prefixed-id functions
      headers.ex               # Layer 1's put_headers step + moduledoc section
      credential.ex            # Layer 1's put_api_key / credential steps + moduledoc section
      base_url.ex              # Layer 1's @base_url or resolve_base_url step + moduledoc section
      values.ex                # one value's lookup code (config / option / resolver)
      mocks.ex                 # test/support/mocks.ex
    integration/
      manifest.ex              # the files an integration consists of (gen + regen)
      names.ex                 # pick integrations from names / --all (regen + diff)
      load.ex                  # any source (file / URL / shortcut) → spec (Igniter-guarded)
      reprune.ex               # source + tags: → pruned spec (Igniter-guarded)
      messages.ex              # text shared by regen and diff
    gen/
      messages.ex              # gen's user-facing text, tag discovery
      patches.ex               # deps, mock, test_helper, config (Igniter-guarded)
    regen/
      messages.ex              # regen's user-facing text
      move.ex                  # --module / --remove-old (Igniter-guarded)
      sync.ex                  # --sync: re-prune from source by tags: (Igniter-guarded)
      call_sites.ex            # --sync: rename calls to removed functions (Igniter-guarded)
      external_setup.ex        # seed values the external scaffold lacks (Igniter-guarded)
    diff/
      messages.ex              # diff's report and halts
    fs/
      ownership.ex             # hearth:owned / hearth:collaborating
      content.ex               # read through Igniter's Rewrite (Igniter-guarded)
test/
  hearth/…  mix/tasks/hearth/… # mirror lib/
  mix/tasks/hearth/gen/        # gen's tests, one file per concern
  support/hearth/task_case.ex  # Hearth.TaskCase — Igniter.Test + read-back helpers
  fixtures/specs/              # OAI petstore (3.0), tictactoe (3.1), keyed (API key in query),
                               # Swagger petstore (2.0)
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

- **`hearth.install`** — adds `:hearth` to `.formatter.exs` `import_deps` and
  prints an "installed" or "already installed" notice. It writes no config:
  integrations are tracked by their pruned specs in `priv/hearth/` (the old
  `:hearth_domains` list was dropped).
- **`hearth.gen` pipeline** — install is auto-composed (gated: silent if
  install would be a no-op, `--yes`/test mode accept, else prompt). The
  source — file, URL, or shortcut (normalized to `name@latest` when bare) —
  goes through `Integration.Load` with the `.hearth.exs` registry
  (`Project.load/1`): a file is read through Rewrite; a URL is fetched by
  `Spec.Fetcher` (`:httpc`, TLS verified against the OS store, redirects
  followed; the `:hearth_fetch` igniter assign stubs it, and Igniter test mode
  refuses the network without one) with its format from the extension or the
  content; a shortcut is looked up with `Registry.lookup/2` (project entries
  shadow built-in ones) and loaded from its location. Then decode →
  `Operation.extract/1`
  → selection (`--tag` filter, or the `--n-operations` gate, default 25, which
  halts with a copy-and-edit tag-discovery command). `--integration` and
  `--domain` must camelize to a single alias segment. If **any** generated file
  already exists, gen halts. Otherwise it writes the `Manifest` files, the
  pruned spec, and applies `Patches`.
- **`--list`** — no source: registry shortcuts (project ones marked); a
  shortcut: its versions; a file or URL: the tag-discovery listing. Output goes through `Mix.shell().info/1`
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
  `config … base_url:` (`Render.BaseUrl`); `new/1` (mirrors `Req.new/1`,
  ends with `Req.merge(opts)`), `request/2`, `request!/2`. Bearer / basic /
  API-key (header or query) register an `:api_key` option and attach the credential
  in an appended request step (`put_api_key/1`, `Render.Credential`):
  resolved per request from the option (per call, through every layer) or
  else `config … api_key:`; a string, 0-arity fun or `{m, f, a}`; a caller's
  explicit `auth:` / header / query param wins; the query key goes into the
  URL, never `:params`. The entry's values can change where the credential,
  headers and base URL come from (see **Values**).
  `test/hearth/render/layer1_runtime_test.exs` compiles and runs each variant
  against `Req.Test`.
- **Layer 2** — per operation a `@callback` plus a delegating `def`
  (summary/description as `@doc`), dispatching through
  `Application.get_env(@otp_app, __MODULE__)[:impl] || __MODULE__.Req`. The
  moduledoc ends with a `## Source` footer.
- **Layer 3** — `@behaviour` Layer 2; each function calls
  `<Layer1>.request/2` with the path interpolated in one regex pass; `:get`
  omits `method:`.
- **Generated tests** — `<Int>Test`: `Req.Test` auth assertions. For keyed
  schemes one test per way to supply the credential — config string / fun /
  MFA, per-call string / fun, `new/1`, an explicit credential winning, and
  (query) the key alongside `params:` — so it doubles as usage examples.
  Wrapped in `if Code.ensure_loaded?(Plug.Conn)` (no `plug` dep is added — `req` declares
  it optional for all envs). `<Int>ExternalTest`: `@moduletag :external`, one
  test per operation calling Layer 3 directly; `test_helper.exs` excludes
  `:external`.
- **Wiring (`Patches`)** — adds `{:req, "~> 0.7"}` and
  `{:mox, "~> 1.0", only: [:test]}`, queues `deps.get` when that changed
  `mix.exs`; `defmock` appended idempotently; `test/support` added to
  `elixirc_paths(:test)` via `Igniter.Project.Test.ensure_test_support/1`
  (a project that already sets `elixirc_paths` is left alone); `config/runtime.exs` credential (prod
  raises, dev falls back to `"DEV_NO_<INT>_API_KEY"`); `config/test.exs`
  `impl:` mock and a non-prod `base_url:`; extra servers as commented
  alternates.
- **Pruned spec** — `Prune.prune/2` keeps the selected paths and the
  components reachable by `$ref` from them (`securitySchemes` whole), encoded
  with conventional top-level key order. Plain OpenAPI — no Hearth block.
- **`.hearth.exs`** — `[integrations: [<snake_name>: [module:, source:,
  sources:, source_sha256:, overrides:, headers:, base_url:, base_path:,
  tags:, untagged:, auth:, prefixed_ids:]], registry: %{…}]`.
  `Hearth.Config.parse/1` reads it as data: `Config.Literal` parses it,
  never evaluates it, takes only literals and names the line of anything
  that would run. It then validates it against `Hearth.Config.Schema` (one
  NimbleOptions schema, custom types in `Config.Types`), so every level's
  keys are closed and an error names the entry and the key, with an
  example, and runs the checks across an entry's values
  (`Spec.Values.check/1`). The modules that read a key take it as valid
  (`Values.parse/1`, `Overrides.parse/1` and `PrefixedIds.parse/1` can't
  fail) and keep only the checks that need the spec; regen resolves
  `prefixed_ids:` once per integration and passes it down.
  `source_sha256` is the source's checksum at the last gen / `--sync`
  (`Reprune.sha256/1`).
  `tags:` (`Hearth.Spec.Selection.describe/2`) lists every tag in the source
  spec in first-seen order as `:all`, `:none` or `include:` / `exclude:`
  operationId lists; untagged operations go under `untagged:` (omitted when
  there are none). It is the selection rule (`Selection.rule/1`, `select/2`):
  `regen --sync` re-prunes the source with it, and plain `regen` halts when
  the pruned spec disagrees (`Selection.check/2` — an `include:` id missing,
  a pruned operation it doesn't select, an `:all` tag with nothing pruned; a
  partial tag rewritten as `:all` isn't visible without the source).
  gen writes the entry (`Hearth.Config.Project.put_integration/3`, created
  from a template when missing); writes are Sourceror keyword edits that keep
  the user's comments and other entries.
- **`hearth.regen`** — takes comma-separated integration names (each must be a
  single alias segment with a `.hearth.exs` entry; `stripe` → `stripe:` and
  `priv/hearth/stripe.yaml`) or `--all` (every `.hearth.exs` entry); neither,
  or both, halts. Per integration: derives every module from the entry's
  `module:` (halts if missing or not an alias), takes `base_path:` /
  `source:` from it (recomputes if absent; halts if a path falls outside the
  recorded base path), and renders the same `Manifest`. Any failure halts the
  whole run. Refreshes code only — never config, `.hearth.exs` or the pruned
  spec — except the env vars of the entry's `headers:`, and under `--sync` (`Hearth.Regen.Sync`: reads `source:` /
  `sources:` (a file, a URL or a shortcut) via `Integration.Reprune`, rewrites the pruned spec,
  `tags:` and `source_sha256`, notices the `Drift` changes it applied; halts without `tags:`/`source:` or on an empty selection;
  `Sync.extend_external_test/4` offers y/N — `--yes` / test mode accept —
  to append `Render.Tests.external_tests/2` blocks for added operations the
  scaffold doesn't already call, via Igniter's `add_code`, and notices tests
  still calling removed ones). Every regen, `Hearth.Regen.ExternalSetup`
  reads the scaffold's text: a config value whose `<INT>_<KEY>` it never
  mentions gets a seeding `setup` block (`Render.Tests.external_seed_setup/3`,
  `async: true` flipped to false), y/N; an option value it never passes
  (`key:`) gets a notice
  and `--module <Layer1>`: exactly one name, module must end
  in it. It creates the new modules (halts if any exist; the old ones are
  untouched), points the entry's `module:` at them
  (`Hearth.Config.Project.put_module/3`), and wires config via
  `Patches.wire/2`.
  Lives in `Hearth.Regen.Move`; the task passes it a `render` callback and
  the wiring context.
  `--remove-old` (requires a `--module` that differs from the current one)
  also `Igniter.rm`s the old untokened tracked files — scaffold, owned,
  collaborating and unreadable files are kept and listed — and
  `Patches.unwire/3` cuts its config entries, alternates and `defmock`
  by Sourceror range from the text (AST removal crashes Sourceror on its
  trailing-comment blocks and drops comments).
- **Swagger 2.0** — `Integration.Load` runs `Spec.Swagger.to_openapi/1` on a
  `"swagger": "2.0"` source (`converted_from` → gen's notice), so overrides,
  selection, pruning, auth, rendering and drift only see OpenAPI 3.0.3:
  `host` / `basePath` / `schemes` → `servers` (no host: a relative server,
  which `Spec.Servers` turns into the placeholder base URL plus its path);
  `definitions` / `parameters` / `responses` / `securityDefinitions` →
  `components` (refs rewritten; body / formData params referenced by `$ref`
  are inlined); `body` → `requestBody` per `consumes`; `formData` → a form
  `requestBody`; param / header types → `schema` (`collectionFormat` →
  `style` / `explode`); response `schema` → `content` per `produces`;
  `x-nullable`, `type: file`, string `discriminator`. Layer 2's footer shows
  the converted version, so regen matches gen. Fixture: the Swagger
  petstore (`test/fixtures/specs/petstore-swagger-2.0.json`).
- **Several sources** — `sources: [items: "…", orders: "…"]` in place of
  `source:` (`Config.source/1` returns either; `Config.source_label/1` prints
  `items: …, orders: …`). `Integration.Load` loads and converts each, then
  `Spec.Merge.merge/2`: each source's server path moves into its paths; one
  shared host or none (different hosts halt); paths unioned, a path or
  operationId clash halts; identical components kept once, differing ones
  prefixed with the source key in each source (refs rewritten, to a fixpoint,
  since a component then differs through a renamed ref). `keep` — from
  `overrides: [shared: %{"schemas/x" => :key}]` — pins a plain name to one
  source. Splits are returned; `Reprune.splits/2` finds the ones the pruned
  spec had under a plain name, and diff (in the report — Igniter prints only
  issues when there are any) and `--sync` (a warning) suggest the `shared:`
  entry, naming the source whose copy still matches. `source_sha256` is a
  keyword per source; diff names the changed ones. gen with no source
  argument reads `source:` / `sources:` from the `--integration` entry and
  records `sources:`. `diff --source` refuses `sources:`. Layer 2's footer
  shows the label in gen and regen.
- **Overrides** — an entry's `overrides:` (`Spec.Overrides`) corrects the
  source spec before selection: `parse/1` validates it (unknown kinds are an
  error naming the supported ones), `apply/2` rewrites the decoded source and
  returns stale entries. `patches:` (`Spec.Patches`) — JSON pointer → value,
  `nil` removes, `-` appends, maps created on the way; applied first, in
  pointer order, to the OpenAPI 3 form (after Swagger 2 conversion); a value already there or a missing key to remove is stale,
  an unfollowable pointer an error. `tags:` — path globs (`*` crosses `/`),
  `method /glob`, or operationIds; adds to upstream tags. `operation_ids:` —
  upstream operationId (or `"method /path"`) → new operationId, applied after
  tags so both refer to the source as published; a new id or derived function
  name that clashes with another operation is an error (`apply/2` returns
  `{:error, _}`). Downstream — `tags:` lists, code, diff — sees the new ids, and
  `Selection.carry_renames/3` keeps a renamed operation selected.
- **Auth choice** — the entry's `auth: [scheme:, available:]`
  (`Spec.Auth.describe/2`) records the spec's schemes and the wired one.
  `Auth.choose/2` applies `scheme:` — or `Auth.default/1`, the first scheme
  Hearth can wire in the spec's `security` order, basic only when nothing
  else is (basic sends `user:password` base64-encoded) — by making it the only
  top-level `security` requirement (`Auth.select/2`), so the pruned spec
  carries it. gen and `Reprune` choose (an unknown name halts); plain regen
  halts when `scheme:` isn't `Auth.primary/1` of the pruned spec; `--sync` wires
  the credential when the strategy changes (`Patches.wire_credential/4`);
  `Drift` reports a change of strategy as breaking; gen's notice says where
  the credential comes from, or why there isn't one. Applied by gen (from
  an entry written before gen, which gen keeps), and by `Integration.Reprune`
  for `--sync` and diff, so the pruned spec carries the result and plain regen
  needs nothing. Stale entries become a notice in gen, `--sync` and diff.
- **Prefixed ids** — the entry's `prefixed_ids: [functions:, prefixes:]`
  (`Spec.PrefixedIds`): functions named by the user, each mapped to an HTTP
  method (default `[retrieve: :get]`); a prefix names its resource by an
  operationId or a path with exactly one path parameter (`resolve/2`). Layer 1
  gets `parse_url/1` (`Render.PrefixedIds`) — `"cus_123…"` → its resource's
  path, anything else unchanged — and `request/2` / `request!/2` call
  `new(url: parse_url(url))`; Layer 2 gets a callback and dispatcher per
  function, and Layer 3 implements each as `request(id, method: …)`. An
  unknown prefix goes through as a plain path; the API answers it. The
  operations the functions call (`targets/3`) are kept in the pruned spec
  without becoming functions — gen and `Reprune` prune selected ∪ targets;
  regen renders all pruned operations minus unselected targets, and its
  selection check exempts them. A function name an operation already uses
  halts gen (`clashes/2`); gen keeps `prefixed_ids:` and notices the pairs.
- **Headers** — the entry's `headers: ["x-tenant-id": :tenant_id]`
  (names lowercased; values parsed by `Spec.Values`). Layer 1 appends
  `put_headers/1` (`Render.Headers`) with one `header_value/2` clause per
  header, skipped when the header is already set, raising when missing.
  Gen keeps `headers:` and notices required header params common to every
  selected operation that nothing sends (`Spec.Headers.suggestions/3`).
  A header the wired auth scheme sends (`Spec.Headers.sent_by_auth/2`)
  halts gen and regen — `put_api_key/1` would set it first.
- **Values** — where the credential (`auth: [credential:]`), each
  `headers:` value and the base URL (`base_url:`) come from
  (`Spec.Values.parse/1`; each form's shape checked by the schema, shared
  keys and Req option names by `Values.check/1` when the file is read):
  `key` — the option, else config, `<INT>_<KEY>` wired into runtime.exs
  (the default credential `:api_key`; `base_url: :base_url` wires
  `<INT>_BASE_URL`, dev without a placeholder); `[option: key]` — the option
  only, nothing wired; `[resolve: {M, :f}, options: [...]]` — `M.f/1` given
  those request options, after the `:api_key` / `:base_url` option for the
  credential / base URL; a non-string raises without showing the value.
  `Render.Values` renders each lookup inline, so an option or resolver
  value never reaches `Application.get_env` (and `@otp_app` is left out
  when nothing reads config); a resolved or per-call base URL drops
  `@base_url` for a `resolve_base_url/1` step prepended before Req's
  `put_base_url`; a resolver gives the host and the spec's base path
  (server path + folded prefix) is kept as `@base_path` and appended,
  while a per-call `base_url:` is used as is. The client test seeds config values in app env and puts
  the others in `@opts` on every request (resolvers never run); the external
  scaffold reads option values from `<INT>_<KEY>` into an `opts/0` and lets
  resolvers run live. `Patches.wire_values/4` wires the bare keys — from gen,
  and from every regen for headers, the base URL and an explicit
  `credential:` (entry-driven, so no `--sync`); regen notices runtime.exs
  lines for values that moved off config (it doesn't remove config). Gen
  keeps `credential:` and `base_url:` in the entry, and `--sync` keeps
  `credential:` when it rewrites `auth:` (`Auth.with_credential/2`); with `base_url:` set the
  no-servers warning is skipped. Golden case `values`.
- **Call sites on `--sync`** — `Regen.CallSites` reads the old Layer 2's
  `@callback`s before rendering; a callback that's gone because an operation
  was renamed, or is now covered by a prefixed-id function, maps to its
  replacement (`replacements/4`). After a y/N prompt (`--yes` / test mode
  accept) it runs `Igniter.Refactors.Rename.rename_function/4` on Layer 2 and
  Layer 3 and rewrites the function atom in Mox `expect` / `stub` calls on the
  mock. `Igniter.update_all_elixir_files/2` runs once per igniter (it marks
  files included and skips later updaters), so each pass clears
  `assigns.private.included_all_elixir_files?` first. The external test's
  "added" means a function the old Layer 2 didn't have, minus rename targets.
- **`hearth.diff`** — same names / `--all` as regen (`Integration.Names`).
  Per integration: reads the pruned spec, re-prunes `source:` (or
  `--source`, one integration only) with `tags:` via
  `Integration.Reprune`, and compares with `Spec.Drift.compare/2`:
  operations by method + path (moves matched by `operationId`, breaking
  when the path-param count changes; an `operationId`-only rename is not
  breaking — the detail names the old → new function from
  `Operation.extract/1` — and `Selection.carry_renames/3`, applied in
  `Reprune.run/4` given the current pruned spec, keeps a renamed operation
  selected under a partial tag; `--sync` then records the new id and
  notices external tests still calling the old function),
  parameters / request body / responses with local `$ref`s resolved, and
  `components/schemas` by name, all through `Drift.Schema` (properties,
  `required`, `enum`, `type`, `$ref`, `items`, compositions; annotations
  ignored). `Selection.unlisted/2` lists new upstream operations `tags:`
  doesn't mention (informational). `source_sha256` (written by gen and
  `--sync`) says whether the source changed since. Drift is an Igniter
  issue — `--fail-on breaking` downgrades additive-only drift to a notice
  — and `run/1` exits 1 on issues. `--sync` prints the same
  `Drift.format/1` lines for what it applied. Writes nothing.

---

## Load-bearing contracts

Learned the hard way; every change must keep them:

- **Every commit produces visibly different behavior for distinct user
  inputs.** Skeletons that no-op identically on every input are misleading.
- **Consumer-facing text never references internal docs or step numbers.**
  Enforced in `gen/install_and_docs_test.exs` "consumer-facing docs".
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
- **Public API discipline.** Only `Hearth` and the Mix tasks are public.
  Everything under `lib/hearth/` is `@moduledoc false`.
- **Hex docs are the front door.** The README's first 30 lines must be enough
  to decide whether to install Hearth.
- **`examples/`** — `stripe_demo` and `ohip_demo`, apps that use Hearth as a
  path dependency (`../..`), so they run against the working tree. The
  README's Examples section links them; their READMEs are walkthroughs.

### Pending

- **Resolve `stripe@latest` in `--list`** — fetch the floating spec and show
  which dated release it is (TODO on the `latest` entry in
  `lib/hearth/registry.ex`).

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
