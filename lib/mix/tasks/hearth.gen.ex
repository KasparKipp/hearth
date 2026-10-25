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
        mix hearth.gen <file> --list           # list a spec file's tags

    ## Source modes

    Only local file sources generate code today. URL and registry
    sources are recognized and validated, but generating from them
    needs the HTTP fetcher, which is coming soon.

        # Local file — generates the integration
        mix hearth.gen priv/specs/petstore.yaml --integration Petstore

        # URL — recognized; generation coming soon
        mix hearth.gen https://example.com/openapi.json --integration Acme

        # Registry shortcut — resolves to a canonical URL; generation coming soon
        mix hearth.gen stripe

    ## Registry shortcuts

      Currently available:

        * `stripe` — the Stripe API (https://stripe.com).

      Each shortcut can be pinned to a version with `name@version`. Bare
      `stripe` is shorthand for `stripe@latest`. Run `mix hearth.gen
      <name> --list` to see the available versions for a shortcut. The
      default integration module name is derived from the shortcut via
      `Macro.camelize/1` (`stripe → Stripe`, `google_docs → GoogleDocs`)
      — override with `--integration <Name>` when you want something
      different.

    ## Options

      * `--integration <Name>` — module name for the generated integration
        (e.g. `Stripe`, `Acme`). Required for file sources.
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
        file (`mix hearth.gen priv/specs/petstore.yaml --list`), prints
        the spec's tags and a ready-to-edit `--tag` command. A URL
        source errors until the fetcher lands. Install is never run
        under `--list`.
      * `--yes` — non-interactive mode. Skips the prompt to run
        `mix hearth.install` on a fresh project and accepts any other
        confirmations.

    ## Pipeline status

      * Available now (for file sources) — source recognition (URL /
        file / registry), registry lookup, install gating, YAML/JSON
        decode, operation extraction + tag filtering, Layer 1/2/3
        generation, a Layer 1 auth test, an external integration test
        scaffold, the pruned spec at `priv/hearth/<name>.yaml`, the
        integration's `.hearth.exs` entry, and Mox + config wiring. Update a generated integration with
        `mix hearth.regen` — `hearth.gen` only creates.
      * Coming soon — on-disk cache and HTTP fetcher (for URL /
        registry sources).

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

    alias Hearth.Fs.Content
    alias Hearth.Gen.Messages
    alias Hearth.Gen.Patches
    alias Hearth.Integration.Manifest
    alias Hearth.Render.ModuleNames
    alias Hearth.Spec.BasePath
    alias Hearth.Spec.Filter
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
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
    #   * no source       → print the available shortcut names
    #   * registry source → print available versions for that shortcut
    #     (the @version part of the source is ignored — same answer for
    #     `stripe`, `stripe@latest`, or `stripe@anything-else`)
    #   * any other source → error: --list is registry-only
    defp handle_list(igniter) do
      # --list is pure introspection. Suppress Igniter's end-of-run
      # "No proposed content changes!" line so query-mode commands
      # don't leave that noise behind their actual output.
      igniter = Igniter.assign(igniter, :quiet_on_no_changes?, true)

      case igniter.args.positional[:source] do
        nil ->
          Mix.shell().info(Messages.format_shortcuts())
          igniter

        source ->
          list_for_source(igniter, source, Source.resolve(source))
      end
    end

    defp list_for_source(igniter, _source, {:registry, name_with_version}) do
      base = name_with_version |> String.split("@", parts: 2) |> hd()

      case Hearth.Registry.versions(base) do
        nil ->
          Igniter.add_issue(igniter, Messages.registry_unknown_name_message(base))

        versions ->
          Mix.shell().info(Messages.format_versions(base, versions))
          igniter
      end
    end

    defp list_for_source(igniter, _source, {:file, path}) do
      case decode_file(igniter, path) do
        {:ok, igniter, spec} ->
          operations = Operation.extract(spec)

          Mix.shell().info(
            Messages.tag_discovery(operations,
              source: path,
              integration: igniter.args.options[:integration],
              limit: nil
            )
          )

          igniter

        {:error, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp list_for_source(igniter, source, _other) do
      Igniter.add_issue(
        igniter,
        "hearth.gen: --list works without a source (registry shortcuts), " <>
          "with a registry shortcut (its versions), or with a file path " <>
          "(the spec's tags). A URL source needs the fetcher, which is not " <>
          "yet wired. Got #{inspect(source)}."
      )
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

    defp dispatch_source(igniter) do
      source = igniter.args.positional[:source]

      case Source.resolve(source) do
        {:url, url} ->
          Igniter.add_notice(igniter, Messages.url_notice(url))

        {:file, path} ->
          handle_file_source(igniter, path)

        {:registry, name} ->
          case Hearth.Registry.lookup(name) do
            {:ok, entry} ->
              Igniter.add_notice(igniter, Messages.registry_hit_notice(entry))

            {:error, {:unknown_name, _}} ->
              Igniter.add_issue(igniter, Messages.registry_unknown_name_message(name))

            {:error, {:unknown_version, base, version, available}} ->
              Igniter.add_issue(
                igniter,
                Messages.registry_unknown_version_message(base, version, available)
              )
          end

        {:error, reason} ->
          Igniter.add_issue(igniter, "hearth.gen: #{reason}")
      end
    end

    defp handle_file_source(igniter, path) do
      case decode_file(igniter, path) do
        {:ok, igniter, spec} -> select_and_report(igniter, path, spec)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # Sniff format → existence check → read through Igniter's Rewrite
    # layer (so test fixtures and real files take the same path) →
    # decode. Returns `{:ok, igniter, spec}` (the igniter now has the
    # spec file in its Rewrite) or `{:error, user_message}`. Shared by
    # the generation flow and `mix hearth.gen <file> --list`.
    defp decode_file(igniter, path) do
      with format when format in [:yaml, :json] <- Loader.sniff(path),
           true <- Igniter.exists?(igniter, path) or :missing,
           igniter = Igniter.include_existing_file(igniter, path),
           {:ok, bytes} <- Content.read(igniter, path),
           {:ok, spec} <- Loader.decode(bytes, format) do
        {:ok, igniter, spec}
      else
        :unknown -> {:error, Messages.unsupported_format_message(path)}
        :missing -> {:error, Messages.file_not_found_message(path)}
        {:error, reason} -> {:error, Messages.decode_failed_message(path, reason)}
      end
    end

    # Extract operations, then select a subset: an explicit `--tag`
    # filter, or — with no `--tag` — the operation-count gate.
    defp select_and_report(igniter, path, spec) do
      operations = Operation.extract(spec)
      # Igniter aggregates a `:keep` option into a single list and
      # defaults an absent one to `[]`, so `options[:tag]` is already
      # the full list of `--tag` values.
      tag_values = igniter.args.options[:tag] || []

      with :ok <- validate_n_operations(igniter),
           {:ok, selected} <- resolve_selection(igniter, operations, tag_values) do
        generate(igniter, path, spec, operations, selected)
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

    # `--integration` is required for file sources (registry sources
    # auto-derive it, but registry codegen isn't wired yet). With it,
    # render Layer 1 (raw client), Layer 2 (behaviour), and Layer 3
    # (Req implementation) to disk.
    defp generate(igniter, path, spec, operations, selected) do
      with {:ok, integration} <- fetch_integration(igniter, path),
           :ok <- validate_domain(igniter) do
        write_layers(igniter, path, spec, operations, selected, integration)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp fetch_integration(igniter, path) do
      case igniter.args.options[:integration] do
        nil ->
          {:error, Messages.missing_integration_message(path)}

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

    defp write_layers(igniter, path, spec, operations, selected, integration) do
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
          render_layers(igniter, path, spec, operations, selected, names)

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

    defp render_layers(igniter, path, spec, operations, selected, names) do
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
        |> Hearth.Spec.Prune.prune(selected)
        |> Hearth.Spec.Prune.to_yaml()

      entry =
        [module: names.layer1, source: path, base_path: prefix] ++
          Hearth.Spec.Selection.describe(operations, selected)

      selected = BasePath.strip(selected, prefix)
      pruned_spec_path = Manifest.pruned_spec_path(names.integration)

      files =
        names
        |> Manifest.files(
          otp_app: otp_app,
          auth: auth,
          servers: servers,
          prefix: prefix,
          operations: selected,
          metadata: Manifest.metadata(path, spec)
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
        prefix: prefix
      })
      |> Igniter.add_notice(
        Messages.generated_notice(
          path,
          spec,
          operations,
          selected,
          Enum.map(files, &{&1.module, &1.location, &1.label}),
          Patches.wired_files(auth) ++
            ["#{pruned_spec_path} (pruned spec)", ".hearth.exs (integration entry)"]
        )
      )
    end

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
