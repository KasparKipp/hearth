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

        mix hearth.gen <source> [--integration <Name>] [--tag <Tag>] [--domain <Name>] [--n-operations <N>] [--refresh] [--yes]
        mix hearth.gen --list                  # list shortcut names
        mix hearth.gen <name> --list           # list versions for a shortcut

    ## Source modes

        # Local file
        mix hearth.gen priv/specs/petstore.yaml --integration Petstore

        # URL
        mix hearth.gen https://example.com/openapi.json --integration Acme

        # Registry shortcut — curated name resolves to a canonical URL
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
        (e.g. `Stripe`, `Acme`). Required for file and URL sources;
        auto-derived from the registry entry when using a registry name.
      * `--domain <Name>` — optional domain segment under your app's
        namespace. With `--domain Billing`, the integration is generated
        at `MyApp.Billing.Integrations.<Name>` instead of
        `MyApp.Integrations.<Name>`. (See "Module layout" in the README.)
      * `--refresh` — for URL and registry sources, bypass the on-disk
        cache and re-fetch the spec. No-op for file sources.
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
      * `--list` — introspect the registry and exit. Without a source,
        prints the shortcut names. With a registry shortcut as the
        source (e.g. `mix hearth.gen stripe --list`), prints the
        available versions for that shortcut. Non-registry sources
        produce an error. Install is never run under `--list`.
      * `--yes` — non-interactive mode. Skips the prompt to run
        `mix hearth.install` on a fresh project and accepts any other
        confirmations.

    ## Pipeline status

      * Available now — source recognition (URL / file / registry),
        registry lookup, file-existence validation, install gating,
        YAML/JSON decode, operation extraction + tag filtering, and
        Layer 2 behaviour generation (for file sources).
      * Coming soon — Layer 1 (raw client), Layer 3 (implementation),
        Mox + config wiring, on-disk cache, HTTP fetcher (for URL /
        registry sources).

    If your project is not yet set up (no `:hearth` in `.formatter.exs`
    or no `:hearth_domains` in `config/config.exs`), `hearth.gen` will
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
          refresh: :boolean,
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
          Igniter.add_issue(igniter, missing_source_message())

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
          Mix.shell().info(format_shortcuts())
          igniter

        source ->
          list_for_source(igniter, source, Source.resolve(source))
      end
    end

    defp list_for_source(igniter, _source, {:registry, name_with_version}) do
      base = name_with_version |> String.split("@", parts: 2) |> hd()

      case Hearth.Registry.versions(base) do
        nil ->
          Igniter.add_issue(igniter, registry_unknown_name_message(base))

        versions ->
          Mix.shell().info(format_versions(base, versions))
          igniter
      end
    end

    defp list_for_source(igniter, source, _other) do
      Igniter.add_issue(
        igniter,
        "hearth.gen: --list with a source only works for registry " <>
          "shortcuts (got #{inspect(source)}). Run `mix hearth.gen " <>
          "--list` without a source to see available shortcuts."
      )
    end

    defp format_shortcuts do
      shortcuts = Enum.map_join(Hearth.Registry.list(), "\n", &"  * #{&1}")

      """
      Hearth shortcuts:

      #{shortcuts}

      Pass a shortcut to mix hearth.gen, e.g. `mix hearth.gen stripe`.
      Run `mix hearth.gen <name> --list` to see versions for a shortcut.
      """
    end

    defp format_versions(name, versions) do
      list = Enum.map_join(versions, "\n", &"  * #{&1}")

      """
      #{name} versions:

      #{list}

      Pin with `name@version`, e.g. `mix hearth.gen #{name}@#{List.last(versions)}`.
      Bare `mix hearth.gen #{name}` resolves to @latest.
      """
    end

    defp missing_source_message do
      """
      hearth.gen: pass a source to generate from.

        mix hearth.gen <source>           # see source modes below
        mix hearth.gen --list             # show registered shortcuts
        mix hearth.gen <name> --list      # show versions for a shortcut

      Source modes:
        * file:     priv/specs/<api>.yaml
        * URL:      https://example.com/openapi.json
        * registry: stripe   (run with --list for the full set)

      Run `mix help hearth.gen` for full options.
      """
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

        Mix.shell().yes?(install_prompt()) ->
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

    defp install_prompt do
      """
      hearth.gen needs `mix hearth.install` to set up your project's
      formatter import and :hearth_domains config. Run install now?
      """
    end

    defp dispatch_source(igniter) do
      source = igniter.args.positional[:source]

      case Source.resolve(source) do
        {:url, url} ->
          Igniter.add_notice(igniter, url_notice(url))

        {:file, path} ->
          handle_file_source(igniter, path)

        {:registry, name} ->
          case Hearth.Registry.lookup(name) do
            {:ok, entry} ->
              Igniter.add_notice(igniter, registry_hit_notice(entry))

            {:error, {:unknown_name, _}} ->
              Igniter.add_issue(igniter, registry_unknown_name_message(name))

            {:error, {:unknown_version, base, version, available}} ->
              Igniter.add_issue(
                igniter,
                registry_unknown_version_message(base, version, available)
              )
          end

        {:error, reason} ->
          Igniter.add_issue(igniter, "hearth.gen: #{reason}")
      end
    end

    defp url_notice(url) do
      """
      Source recognized: URL.

          #{url}

      Next pipeline stage: HTTP fetch (Req-based, with on-disk cache under
      `priv/hearth/cache/<sha256>/`). Not yet wired — when ready, this
      command will fetch and cache the spec before decoding it.
      """
    end

    # File-source flow:
    #
    #   1. Sniff the format from the extension. Unsupported → halt.
    #   2. Existence check via Igniter (works against both real disk and
    #      `test_project(files: %{...})` virtual fs).
    #   3. Pull bytes through Igniter's Rewrite layer so test fixtures and
    #      real files take the same path.
    #   4. Decode via Hearth.Spec.Loader. Decode failures halt with the
    #      parser's message attached.
    #   5. Summarize: title, info.version, OpenAPI spec version, path
    #      count, operation count (sum of HTTP-method keys per path-item).
    defp handle_file_source(igniter, path) do
      case Loader.sniff(path) do
        :unknown ->
          Igniter.add_issue(igniter, unsupported_format_message(path))

        format when format in [:yaml, :json] ->
          if Igniter.exists?(igniter, path) do
            load_local_spec(igniter, path, format)
          else
            Igniter.add_issue(igniter, file_not_found_message(path))
          end
      end
    end

    defp load_local_spec(igniter, path, format) do
      igniter = Igniter.include_existing_file(igniter, path)

      with {:ok, bytes} <- read_rewrite_content(igniter, path),
           {:ok, spec} <- Loader.decode(bytes, format) do
        select_and_report(igniter, path, spec)
      else
        {:error, reason} ->
          Igniter.add_issue(igniter, decode_failed_message(path, reason))
      end
    end

    defp read_rewrite_content(igniter, path) do
      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} -> {:ok, Rewrite.Source.get(source, :content)}
        :error -> {:error, :file_not_in_rewrite}
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

      case resolve_selection(igniter, operations, tag_values) do
        {:ok, selected} ->
          generate(igniter, path, spec, operations, selected)

        {:halt, message} ->
          Igniter.add_issue(igniter, message)
      end
    end

    # `--integration` is required for file sources (registry sources
    # auto-derive it, but registry codegen isn't wired yet). With it,
    # render the Layer 2 behaviour and write it to disk.
    defp generate(igniter, path, spec, operations, selected) do
      case igniter.args.options[:integration] do
        nil ->
          Igniter.add_issue(igniter, missing_integration_message(path))

        integration ->
          module = layer2_module(igniter, integration)
          source = Hearth.Render.Layer2.render(module, selected)
          location = Igniter.Project.Module.proper_location(igniter, module)

          igniter
          |> Igniter.create_new_file(location, source, on_exists: :overwrite)
          |> Igniter.add_notice(
            generated_notice(path, spec, operations, selected, module, location)
          )
      end
    end

    defp layer2_module(igniter, integration) do
      app =
        igniter
        |> Igniter.Project.Application.app_name()
        |> to_string()
        |> Macro.camelize()

      Hearth.Render.ModuleNames.layer2(
        app_module: app,
        integration: Macro.camelize(integration),
        domain: domain_segment(igniter)
      )
    end

    defp domain_segment(igniter) do
      case igniter.args.options[:domain] do
        nil -> nil
        domain -> Macro.camelize(domain)
      end
    end

    defp resolve_selection(igniter, operations, []) do
      limit = igniter.args.options[:n_operations] || @default_n_operations

      if length(operations) <= limit do
        {:ok, operations}
      else
        {:halt, discovery_message(operations, limit)}
      end
    end

    defp resolve_selection(_igniter, operations, tag_values) do
      case Filter.parse(tag_values) do
        {:ok, filter} -> {:ok, Filter.apply(operations, filter)}
        {:error, reason} -> {:halt, "hearth.gen: #{reason}"}
      end
    end

    defp summarize(spec) when is_map(spec) do
      %{
        title: get_in(spec, ["info", "title"]) || "<untitled>",
        info_version: get_in(spec, ["info", "version"]) || "<unversioned>",
        openapi: Map.get(spec, "openapi", "<unknown>"),
        paths: paths_count(spec)
      }
    end

    defp summarize(_), do: %{title: "<not a map>", info_version: "?", openapi: "?", paths: 0}

    defp paths_count(spec) do
      case Map.get(spec, "paths") do
        paths when is_map(paths) -> map_size(paths)
        _ -> 0
      end
    end

    defp generated_notice(path, spec, operations, selected, module, location) do
      summary = summarize(spec)
      tag_count = selected |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> length()
      callbacks = pluralize("callback", length(selected))

      """
      Spec loaded from #{path}.

          #{summary.title} (info.version #{summary.info_version}, OpenAPI #{summary.openapi})

      Selected #{length(selected)} of #{length(operations)} operations \
      across #{tag_count} #{pluralize("tag", tag_count)}.

      * generating #{location}
          #{inspect(module)} — behaviour, #{length(selected)} #{callbacks}

      Next pipeline stage: Layer 1 (raw Req client), Layer 3
      (implementation), and Mox wiring. Not yet wired.
      """
    end

    defp missing_integration_message(path) do
      """
      hearth.gen: --integration is required for a file source.

        mix hearth.gen #{path} --integration <Name>

      <Name> becomes the integration's module name — `--integration Stripe`
      generates the behaviour at App.Integrations.Stripe.StripeApi.
      """
    end

    defp discovery_message(operations, limit) do
      tag_lines =
        operations
        |> Operation.tag_index()
        |> Enum.sort_by(&tag_sort_key/1)
        |> Enum.map_join("\n", &tag_listing_line/1)

      total = length(operations)

      """
      This spec has #{total} operations, above the --n-operations limit (#{limit}).

      Tags in this spec — pass a subset with one or more --tag flags:

      #{tag_lines}

      Generate a subset, e.g.:
        mix hearth.gen <source> --integration <Name> --tag "<Tag>"

      Or generate everything:
        mix hearth.gen <source> --integration <Name> --n-operations #{total}
      """
    end

    defp tag_sort_key({:untagged, _ops}), do: {1, ""}
    defp tag_sort_key({tag, _ops}), do: {0, tag}

    defp tag_listing_line({tag, ops}) do
      ids = Enum.map_join(ops, ", ", &":#{&1.id}")
      "  #{tag_label(tag)}: [#{ids}]"
    end

    defp tag_label(:untagged), do: ":untagged"
    defp tag_label(tag) when is_binary(tag), do: inspect(tag)

    defp pluralize(word, 1), do: word
    defp pluralize(word, _count), do: word <> "s"

    defp file_not_found_message(path) do
      "hearth.gen: file not found at #{inspect(path)}. " <>
        "Check the path is correct and relative to the project root."
    end

    defp unsupported_format_message(path) do
      "hearth.gen: unsupported spec format for #{inspect(path)}. " <>
        "Supported extensions: .yaml, .yml, .json."
    end

    defp decode_failed_message(path, reason) do
      "hearth.gen: failed to parse spec at #{path}.\n\n" <> format_reason(reason)
    end

    defp format_reason(%{__exception__: true} = ex), do: Exception.message(ex)
    defp format_reason(reason), do: inspect(reason)

    defp registry_hit_notice(entry) do
      %{
        name: name,
        version: version,
        resolved_version: resolved,
        url: url,
        integration: integration
      } = entry

      header =
        if version == resolved do
          "Source recognized: registry shorthand `#{name}@#{version}`."
        else
          "Source recognized: registry shorthand `#{name}@#{version}` " <>
            "(alias for `#{name}@#{resolved}`)."
        end

      """
      #{header}

      Resolved to:
          #{url}

      Default integration name: #{integration} (override with --integration).

      Next pipeline stage: HTTP fetch (Req-based, with on-disk cache under
      `priv/hearth/cache/<sha256>/`). Not yet wired — when ready, this
      command will fetch and cache the spec before decoding it.
      """
    end

    defp registry_unknown_name_message(name) do
      available = Enum.map_join(Hearth.Registry.list(), "\n", &"  * #{&1}")

      """
      hearth.gen: no registry entry for `#{name}`.

      Currently available shortcuts:
      #{available}

      Pin a version with `name@version` (e.g. `stripe@latest`). If you
      have an OpenAPI spec elsewhere, pass it as a file path or URL
      instead.
      """
    end

    defp registry_unknown_version_message(name, version, available) do
      versions_block = Enum.map_join(available, "\n", &"  * #{name}@#{&1}")

      """
      hearth.gen: registry shortcut `#{name}` has no version `#{version}`.

      Available versions:
      #{versions_block}
      """
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
