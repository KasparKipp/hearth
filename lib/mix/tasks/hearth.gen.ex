defmodule Mix.Tasks.Hearth.Gen.Docs do
  @moduledoc false

  def short_doc do
    "Generates a Hearth integration from an OpenAPI spec. Requires igniter to run."
  end

  def example do
    "mix hearth.gen priv/specs/petstore.yaml --integration Petstore"
  end

  def long_doc do
    """
    #{short_doc()}

    ## Usage

        mix hearth.gen <source> --integration <Name> [--tag <Tag>] [--domain <Name> | --no-domain] [--n-operations <N>] [--yes]
        mix hearth.gen --list                  # list shortcut names
        mix hearth.gen <name> --list           # list versions for a shortcut
        mix hearth.gen <file | url> --list     # list a spec's tags

    ## Sources

    A source is a local spec file, an http(s) URL, or a registry
    shortcut. All three generate code.

        # Local file
        mix hearth.gen priv/specs/petstore.yaml --integration Petstore

        # URL — fetched on every gen / sync / diff, never cached
        mix hearth.gen https://example.com/openapi.json --integration Acme

        # Registry shortcut — Hearth's, or one in your .hearth.exs
        mix hearth.gen stripe@2026-04-22.dahlia --tag "Customers:GetCustomers"

    The source is recorded as the integration's `.hearth.exs`
    `source:` exactly as given (a bare shortcut as `name@latest`), so
    `mix hearth.regen --sync` and `mix hearth.diff` re-read it. A
    shortcut is resolved again each time — `stripe@latest` follows
    Stripe's latest spec.

    ## Registry shortcuts

      Currently available:

        * `stripe` — the Stripe API (https://stripe.com).

      Your project can declare its own in `.hearth.exs`, with the same
      shape — a version points at a URL or a file, and
      `{:alias, version}` points at another version. A project name
      shadows a Hearth one:

          registry: %{
            "acme" => %{
              "1.0" => "https://acme.example.com/openapi-1.0.json",
              "latest" => {:alias, "1.0"}
            }
          }

      Each shortcut can be pinned to a version with `name@version`. Bare
      `stripe` is shorthand for `stripe@latest`. Run `mix hearth.gen
      <name> --list` to see the available versions for a shortcut. The
      default integration module name is derived from the shortcut via
      `Macro.camelize/1` (`stripe → Stripe`, `google_docs → GoogleDocs`)
      — override with `--integration <Name>` when you want something
      different.

    ## Options

      * `--integration <Name>` — module name for the generated integration
        (e.g. `Stripe`, `Acme`). Required for a file or URL source; a
        registry shortcut defaults it to the shortcut's name.
      * `--domain <Name>` — the single namespace segment between your
        app and the integration. Defaults to `Integrations`
        (`MyApp.Integrations.<Name>`); `--domain Billing` overrides it
        wholesale (`MyApp.Billing.<Name>`). You pick the layout —
        Hearth does not lock you into `Integrations`.
      * `--no-domain` — drop the namespace segment entirely:
        `MyApp.<Name>`. Takes precedence over `--domain`.
      * `--tag <Tag>` — repeatable. Restrict generation to the named
        OpenAPI tag. `--tag "Customers"` takes every operation under
        that tag; `--tag "Subscriptions:create_sub,list_sub"` narrows
        to specific operationIds (the first `:` delimits, ids are
        comma-separated). Repeat the flag for multiple tags.
      * `--n-operations <N>` — operation-count gate (default 25). When
        no `--tag` is given and the spec has more than `N` operations,
        the task halts with a tag-discovery listing instead of
        generating everything. Pass the spec's actual operation count
        to bypass the gate.
      * `--list` — introspect and exit, generating nothing. Without a
        source, prints the registry shortcut names. With a shortcut
        (`mix hearth.gen stripe --list`), prints its versions. With a
        file (`mix hearth.gen priv/specs/petstore.yaml --list`) or a
        URL, prints the spec's tags and a ready-to-edit `--tag`
        command. Install is never run under `--list`.
      * `--yes` — non-interactive mode. Skips the prompt to run
        `mix hearth.install` on a fresh project and accepts any other
        confirmations.

    ## Pipeline status

      * Available now — file, URL and registry sources (Hearth's and
        `.hearth.exs`), install gating, YAML/JSON decode, operation
        extraction + tag filtering, Layer 1/2/3
        generation, a Layer 1 auth test, an external integration test
        scaffold, the pruned spec at `priv/hearth/<name>.yaml`, the
        integration's `.hearth.exs` entry, and Mox + config wiring. Update a generated integration with
        `mix hearth.regen` — `hearth.gen` only creates.

    If your project is not yet set up (no `:hearth` in `.formatter.exs`),
    `hearth.gen` will
    prompt to run `mix hearth.install` first. Pass `--yes` to skip the
    prompt. On an already-installed project the install step is silently
    skipped — no extra noise.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Hearth.Gen do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Hearth.Config
    alias Hearth.Config.Project
    alias Hearth.Gen.Messages
    alias Hearth.Gen.Patches
    alias Hearth.Integration.Load
    alias Hearth.Integration.Manifest
    alias Hearth.Integration.Messages, as: IntegrationMessages
    alias Hearth.Integration.Reprune
    alias Hearth.Render.ModuleNames
    alias Hearth.Spec.BasePath
    alias Hearth.Spec.Filter
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Overrides
    alias Hearth.Spec.Source

    # Default operation-count gate: above this, an unfiltered spec halts
    # with the tag-discovery listing instead of selecting everything.
    @default_n_operations 25

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [
          integration: :string,
          domain: :string,
          no_domain: :boolean,
          list: :boolean,
          tag: :keep,
          n_operations: :integer,
          yes: :boolean
        ],
        # `:source` is optional so `mix hearth.gen --list` (and an empty
        # invocation) can be intercepted in igniter/1 with task-specific
        # messages rather than Igniter's generic "required positional"
        # error.
        positional: [{:source, optional: true}],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      cond do
        igniter.args.options[:list] ->
          # Pure introspection — skip install gating entirely.
          handle_list(igniter)

        is_nil(igniter.args.positional[:source]) ->
          Igniter.add_issue(igniter, Messages.missing_source_message())

        true ->
          case ensure_installed(igniter) do
            {:ok, igniter} -> dispatch_source(igniter)
            {:halt, igniter} -> igniter
          end
      end
    end

    # --list semantics:
    #
    #   * no source       → print the available shortcut names (Hearth's
    #     and the project's `.hearth.exs` registry)
    #   * registry source → print available versions for that shortcut
    #     (the @version part of the source is ignored — same answer for
    #     `stripe`, `stripe@latest`, or `stripe@anything-else`)
    #   * a file or URL   → load it and print its tag discovery
    defp handle_list(igniter) do
      # --list is pure introspection. Suppress Igniter's end-of-run
      # "No proposed content changes!" line so query-mode commands
      # don't leave that noise behind their actual output.
      igniter = Igniter.assign(igniter, :quiet_on_no_changes?, true)

      case Project.load(igniter) do
        {:ok, igniter, %{registry: registry}} ->
          list(igniter, igniter.args.positional[:source], registry)

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp list(igniter, nil, registry) do
      Mix.shell().info(Messages.format_shortcuts(registry))
      igniter
    end

    defp list(igniter, source, registry) do
      case Source.resolve(source) do
        {:registry, name_with_version} -> list_versions(igniter, name_with_version, registry)
        {:error, reason} -> Igniter.add_issue(igniter, "hearth.gen: #{reason}")
        _location -> list_tags(igniter, source, registry)
      end
    end

    defp list_versions(igniter, name_with_version, registry) do
      base = name_with_version |> String.split("@", parts: 2) |> hd()

      case Hearth.Registry.versions(base, registry) do
        nil ->
          reason = {:registry, {:unknown_name, base}}

          Igniter.add_issue(
            igniter,
            IntegrationMessages.load_message(:gen, base, reason, registry)
          )

        versions ->
          Mix.shell().info(Messages.format_versions(base, versions))
          igniter
      end
    end

    defp list_tags(igniter, source, registry) do
      case Load.load(igniter, source, registry) do
        {:ok, igniter, loaded} ->
          Mix.shell().info(
            Messages.tag_discovery(Operation.extract(loaded.spec),
              source: source,
              integration: igniter.args.options[:integration],
              limit: nil
            )
          )

          igniter

        {:error, reason} ->
          Igniter.add_issue(
            igniter,
            IntegrationMessages.load_message(:gen, source, reason, registry)
          )
      end
    end

    # Speculatively compose `hearth.install` to find out what (if anything)
    # it would change. Three outcomes:
    #
    #   1. install is a no-op → discard the speculative result and proceed
    #      silently. The consumer sees only gen's own notice.
    #   2. install would touch files AND (--yes OR test mode) → use the
    #      composed igniter (install's notices and patches included).
    #   3. install would touch files AND interactive → prompt; if accepted
    #      use the composed igniter; if refused halt with an issue.
    @install_touched_files [".formatter.exs", "config/config.exs"]

    defp ensure_installed(igniter) do
      composed = Igniter.compose_task(igniter, "hearth.install", [])

      cond do
        not Igniter.has_changes?(composed, @install_touched_files) ->
          {:ok, igniter}

        igniter.args.options[:yes] || igniter.assigns[:test_mode?] ->
          {:ok, composed}

        Mix.shell().yes?(Messages.install_prompt()) ->
          {:ok, composed}

        true ->
          {:halt,
           Igniter.add_issue(
             igniter,
             "hearth.gen needs `mix hearth.install` to run first. " <>
               "Re-run with --yes to install automatically, or run " <>
               "`mix hearth.install` manually."
           )}
      end
    end

    # Any source — a file, a URL, or a registry shortcut (the project's
    # `.hearth.exs` registry first, then Hearth's) — goes through
    # `Hearth.Integration.Load`. What gen records as the entry's
    # `source:` is the source as typed, with a bare shortcut pinned to
    # `@latest`.
    defp dispatch_source(igniter) do
      with {:ok, source} <- normalize_source(igniter.args.positional[:source]),
           {:ok, igniter, config} <- Project.load(igniter),
           {:ok, igniter, loaded} <- load(igniter, source, config.registry),
           {:ok, overrides} <- overrides(igniter, loaded, config.integrations),
           {:ok, spec, stale} <- apply_overrides(loaded.spec, overrides),
           {:ok, spec, auth} <- choose_auth(spec, overrides),
           {:ok, prefixed} <- prefixed_ids(spec, overrides),
           {:ok, headers} <- headers(overrides) do
        input = %{
          source: source,
          spec: spec,
          sha256: Reprune.sha256(loaded.bytes),
          entry: loaded.entry,
          overrides: overrides.raw,
          auth: auth,
          prefixed: prefixed,
          prefixed_raw: overrides.entry[:prefixed_ids],
          headers: headers,
          headers_raw: overrides.entry[:headers]
        }

        igniter
        |> resolved_notice(input)
        |> converted_notice(loaded.converted_from)
        |> stale_notice(overrides.key, source, stale)
        |> select_and_report(input)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp apply_overrides(spec, overrides) do
      case Overrides.apply(spec, overrides.parsed) do
        {:ok, spec, stale} ->
          {:ok, spec, stale}

        {:error, detail} ->
          {:error, IntegrationMessages.bad_overrides_message(:gen, overrides.key, detail)}
      end
    end

    # An entry written before gen may carry `prefixed_ids:` — kept, and
    # resolved against the source here.
    defp prefixed_ids(spec, overrides) do
      case Hearth.Spec.PrefixedIds.prepare(spec, overrides.entry) do
        {:ok, prefixed} ->
          {:ok, prefixed}

        {:error, detail} ->
          {:error, IntegrationMessages.bad_prefixed_ids_message(:gen, overrides.key, detail)}
      end
    end

    # Like `prefixed_ids:`, kept from an entry written before gen.
    defp headers(overrides) do
      case Hearth.Spec.Headers.parse(overrides.entry) do
        {:ok, headers} ->
          {:ok, headers}

        {:error, detail} ->
          {:error, IntegrationMessages.bad_headers_message(:gen, overrides.key, detail)}
      end
    end

    defp choose_auth(spec, overrides) do
      case Hearth.Spec.Auth.choose(spec, overrides.entry) do
        {:ok, spec, auth} ->
          {:ok, spec, auth}

        {:error, {:bad_auth, name, available}} ->
          {:error, IntegrationMessages.bad_auth_message(:gen, overrides.key, name, available)}
      end
    end

    defp normalize_source(source) do
      case Source.resolve(source) do
        {:registry, name} -> {:ok, if(name =~ "@", do: name, else: name <> "@latest")}
        {:error, reason} -> {:error, "hearth.gen: #{reason}"}
        _location -> {:ok, source}
      end
    end

    defp load(igniter, source, registry) do
      case Load.load(igniter, source, registry) do
        {:ok, igniter, loaded} ->
          {:ok, igniter, loaded}

        {:error, reason} ->
          {:error, IntegrationMessages.load_message(:gen, source, reason, registry)}
      end
    end

    # A `.hearth.exs` entry written before gen may carry `overrides:`
    # (applied to the source before selection, and kept) and an
    # `auth: [scheme: …]` choice.
    defp overrides(igniter, loaded, integrations) do
      name = igniter.args.options[:integration] || (loaded.entry && loaded.entry.integration)
      key = if name && ModuleNames.valid_segment?(name), do: Config.key(name)
      entry = (key && integrations[key]) || []
      raw = entry[:overrides]

      case Overrides.parse(overrides: raw || []) do
        {:ok, parsed} -> {:ok, %{key: key, entry: entry, raw: raw, parsed: parsed}}
        {:error, detail} -> {:error, IntegrationMessages.bad_overrides_message(:gen, key, detail)}
      end
    end

    defp stale_notice(igniter, _key, _source, []), do: igniter

    defp stale_notice(igniter, key, source, stale),
      do:
        Igniter.add_notice(
          igniter,
          IntegrationMessages.stale_overrides_notice(key, source, stale)
        )

    defp converted_notice(igniter, nil), do: igniter

    defp converted_notice(igniter, from),
      do: Igniter.add_notice(igniter, Messages.converted_notice(from))

    defp resolved_notice(igniter, %{entry: nil}), do: igniter

    defp resolved_notice(igniter, %{source: source, entry: entry}),
      do: Igniter.add_notice(igniter, Messages.resolved_notice(source, entry))

    # Extract operations, then select a subset: an explicit `--tag`
    # filter, or — with no `--tag` — the operation-count gate.
    defp select_and_report(igniter, input) do
      operations = Operation.extract(input.spec)
      # Igniter aggregates a `:keep` option into a single list and
      # defaults an absent one to `[]`, so `options[:tag]` is already
      # the full list of `--tag` values.
      tag_values = igniter.args.options[:tag] || []

      with :ok <- validate_n_operations(igniter),
           {:ok, selected} <- resolve_selection(igniter, operations, tag_values) do
        generate(igniter, input, operations, selected)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
        {:halt, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp validate_n_operations(igniter) do
      case igniter.args.options[:n_operations] do
        nil -> :ok
        n when n >= 1 -> :ok
        n -> {:error, "hearth.gen: --n-operations must be a positive integer, got #{n}."}
      end
    end

    # `--integration` is required for a file or URL source; a registry
    # shortcut defaults it to the shortcut's name. With it, render
    # Layer 1 (raw client), Layer 2 (behaviour), and Layer 3 (Req
    # implementation) to disk.
    defp generate(igniter, input, operations, selected) do
      with {:ok, integration} <- fetch_integration(igniter, input),
           :ok <- validate_domain(igniter),
           :ok <- check_prefixed_clash(input, selected, integration) do
        write_layers(igniter, input, operations, selected, integration)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp check_prefixed_clash(input, selected, integration) do
      case Hearth.Spec.PrefixedIds.clashes(input.prefixed, generated(selected, input.prefixed)) do
        [] ->
          :ok

        names ->
          {:error,
           IntegrationMessages.prefixed_clash_message(:gen, Config.key(integration), names)}
      end
    end

    defp fetch_integration(igniter, input) do
      case igniter.args.options[:integration] || (input.entry && input.entry.integration) do
        nil ->
          {:error, Messages.missing_integration_message(input.source)}

        name ->
          if ModuleNames.valid_segment?(name),
            do: {:ok, name},
            else: {:error, Messages.bad_segment("--integration", name)}
      end
    end

    defp validate_domain(igniter) do
      case igniter.args.options[:domain] do
        nil ->
          :ok

        domain ->
          if ModuleNames.valid_segment?(domain),
            do: :ok,
            else: {:error, Messages.bad_segment("--domain", domain)}
      end
    end

    defp write_layers(igniter, input, operations, selected, integration) do
      names =
        igniter
        |> module_names(integration)
        |> ModuleNames.layer1()
        |> ModuleNames.from_layer1()

      # `hearth.gen` only ever creates. *Every* generated artifact is
      # checked — a partial deletion (e.g. only Layer 1 removed) must
      # still halt, never silently clobber the surviving files.
      case existing_artifacts(igniter, names) do
        [] ->
          render_layers(igniter, input, operations, selected, names)

        existing ->
          Igniter.add_issue(igniter, Messages.integration_exists_message(names.layer1, existing))
      end
    end

    # The paths of every file `gen` would create for this integration
    # that already exist on disk.
    defp existing_artifacts(igniter, names) do
      module_paths =
        Enum.map(Manifest.modules(names), fn {module, kind, _policy} ->
          Igniter.Project.Module.proper_location(igniter, module, kind)
        end)

      Enum.filter(
        module_paths ++ [Manifest.pruned_spec_path(names.integration)],
        &Igniter.exists?(igniter, &1)
      )
    end

    defp render_layers(igniter, input, operations, selected, names) do
      %{source: path, spec: spec} = input

      otp_app = Igniter.Project.Application.app_name(igniter)
      auth = Hearth.Spec.Auth.strategy(spec)
      servers = Hearth.Spec.Servers.resolve(spec)

      # A leading path prefix shared by every operation (e.g. `/v3`) is
      # stripped from the operation paths and folded into Layer 1's base
      # URL — see `Hearth.Render.Layer1` for the base-URL side.
      prefix = BasePath.common_prefix(operations)

      # The pruned spec is built from `selected` *before* the path
      # prefix is stripped — it must match the spec's original `paths`
      # keys. The `.hearth.exs` entry records the module, source and
      # prefix so `regen` reproduces them rather than recomputing, and
      # which tags and operations were selected and which left out.
      pruned_spec_yaml =
        spec
        |> Hearth.Spec.Prune.prune(selected ++ prefixed_targets(operations, input.prefixed))
        |> Hearth.Spec.Prune.to_yaml()

      entry =
        [module: names.layer1, source: path, source_sha256: input.sha256] ++
          if(input.overrides, do: [overrides: input.overrides], else: []) ++
          if(input.prefixed_raw, do: [prefixed_ids: input.prefixed_raw], else: []) ++
          if(input.headers_raw, do: [headers: input.headers_raw], else: []) ++
          [base_path: prefix] ++
          Hearth.Spec.Selection.describe(operations, selected) ++
          if(input.auth == [], do: [], else: [auth: input.auth])

      covered = Hearth.Spec.PrefixedIds.covered(selected, input.prefixed)
      selected = selected |> generated(input.prefixed) |> BasePath.strip(prefix)
      pruned_spec_path = Manifest.pruned_spec_path(names.integration)

      files =
        names
        |> Manifest.files(
          otp_app: otp_app,
          auth: auth,
          servers: servers,
          prefix: prefix,
          operations: selected,
          metadata: Manifest.metadata(path, spec),
          prefixed: input.prefixed,
          headers: input.headers
        )
        |> Enum.map(fn file ->
          location = Igniter.Project.Module.proper_location(igniter, file.module, file.kind)
          Map.put(file, :location, location)
        end)

      igniter
      |> Patches.add_deps()
      |> Patches.fetch_deps_if_changed()
      |> write_files(files)
      # Re-derived each run — `on_exists: :overwrite`.
      |> Igniter.create_new_file(pruned_spec_path, pruned_spec_yaml, on_exists: :overwrite)
      |> Hearth.Config.Project.put_integration(Hearth.Config.key(names.integration), entry)
      |> Patches.wire(%{
        otp_app: otp_app,
        names: names,
        auth: auth,
        servers: servers,
        prefix: prefix,
        headers: input.headers
      })
      |> Igniter.add_notice(
        Messages.generated_notice(
          path,
          spec,
          operations,
          selected,
          Enum.map(files, &{&1.module, &1.location, &1.label}),
          Patches.wired_files(auth, input.headers) ++
            ["#{pruned_spec_path} (pruned spec)", ".hearth.exs (integration entry)"],
          Messages.credential_hint(auth, names) <> Messages.headers_hint(input.headers, names)
        )
      )
      |> prefixed_notice(names, input.prefixed, covered)
      |> headers_notice(names, Hearth.Spec.Headers.suggestions(selected, input.headers, auth))
    end

    defp headers_notice(igniter, _names, []), do: igniter

    defp headers_notice(igniter, names, suggestions),
      do: Igniter.add_notice(igniter, Messages.headers_notice(names, suggestions))

    defp prefixed_notice(igniter, _names, nil, _covered), do: igniter

    defp prefixed_notice(igniter, names, prefixed, covered) do
      pairs = Hearth.Spec.PrefixedIds.pairs(prefixed.resources, prefixed.functions)
      Igniter.add_notice(igniter, Messages.prefixed_notice(names.layer2, pairs, covered))
    end

    # The selected operations that get functions of their own: not the
    # ones a prefixed-id function already reaches.
    defp generated(selected, prefixed) do
      covered = Hearth.Spec.PrefixedIds.covered(selected, prefixed)
      selected -- Enum.map(covered, &elem(&1, 0))
    end

    # The operations `prefixed_ids:` functions call: kept in the pruned
    # spec beside the selected ones, without generating functions.
    defp prefixed_targets(_operations, nil), do: []

    defp prefixed_targets(operations, prefixed),
      do: Hearth.Spec.PrefixedIds.targets(operations, prefixed.resources, prefixed.functions)

    # Tracked files are Hearth-owned (`:overwrite`); the scaffold — the
    # external test — is user-owned and never touched once it exists.
    defp write_files(igniter, files) do
      Enum.reduce(files, igniter, fn file, acc ->
        on_exists = if file.policy == :scaffold, do: :skip, else: :overwrite
        Igniter.create_new_file(acc, file.location, file.content, on_exists: on_exists)
      end)
    end

    defp module_names(igniter, integration) do
      app =
        igniter
        |> Igniter.Project.Application.app_name()
        |> to_string()
        |> Macro.camelize()

      [
        app_module: app,
        integration: Macro.camelize(integration),
        domain: domain_segment(igniter)
      ]
    end

    # `--no-domain` → `""` (the segment is dropped); `--domain X` → the
    # camelized `X`; neither → `nil` (the `Integrations` default).
    # `--no-domain` wins if both are given.
    defp domain_segment(igniter) do
      cond do
        igniter.args.options[:no_domain] -> ""
        domain = igniter.args.options[:domain] -> Macro.camelize(domain)
        true -> nil
      end
    end

    defp resolve_selection(igniter, operations, []) do
      limit = igniter.args.options[:n_operations] || @default_n_operations

      if length(operations) <= limit do
        {:ok, operations}
      else
        {:halt,
         Messages.tag_discovery(operations,
           source: igniter.args.positional[:source],
           integration: igniter.args.options[:integration],
           limit: limit
         )}
      end
    end

    defp resolve_selection(igniter, operations, tag_values) do
      with {:ok, filter} <- Filter.parse(tag_values),
           [_first | _rest] = selected <- Filter.apply(operations, filter) do
        {:ok, selected}
      else
        {:error, reason} ->
          {:halt, "hearth.gen: #{reason}"}

        [] ->
          source = igniter.args.positional[:source]

          {:halt,
           "hearth.gen: no operations matched the --tag filter. " <>
             "Run `mix hearth.gen #{source} --list` to see this spec's tags."}
      end
    end
  end
else
  defmodule Mix.Tasks.Hearth.Gen do
    @shortdoc "#{Mix.Tasks.Hearth.Gen.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc Mix.Tasks.Hearth.Gen.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'hearth.gen' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
