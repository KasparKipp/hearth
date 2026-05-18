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
        Layer 1/2/3 generation — raw client, behaviour, and Req
        implementation (for file sources).
      * Coming soon — Mox + config wiring, on-disk cache, HTTP fetcher
        (for URL / registry sources).

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

    defp list_for_source(igniter, _source, {:file, path}) do
      case decode_file(igniter, path) do
        {:ok, igniter, spec} ->
          operations = Operation.extract(spec)

          Mix.shell().info(
            tag_discovery(operations,
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
           {:ok, bytes} <- read_rewrite_content(igniter, path),
           {:ok, spec} <- Loader.decode(bytes, format) do
        {:ok, igniter, spec}
      else
        :unknown -> {:error, unsupported_format_message(path)}
        :missing -> {:error, file_not_found_message(path)}
        {:error, reason} -> {:error, decode_failed_message(path, reason)}
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
    # render Layer 1 (raw client), Layer 2 (behaviour), and Layer 3
    # (Req implementation) to disk.
    defp generate(igniter, path, spec, operations, selected) do
      case igniter.args.options[:integration] do
        nil ->
          Igniter.add_issue(igniter, missing_integration_message(path))

        integration ->
          write_layers(igniter, path, spec, operations, selected, integration)
      end
    end

    defp write_layers(igniter, path, spec, operations, selected, integration) do
      names = module_names(igniter, integration)
      layer1 = Hearth.Render.ModuleNames.layer1(names)
      layer2 = Hearth.Render.ModuleNames.layer2(names)
      layer3 = Hearth.Render.ModuleNames.layer3(names)
      layer1_test = Hearth.Render.ModuleNames.layer1_test(names)

      otp_app = Igniter.Project.Application.app_name(igniter)
      auth = Hearth.Spec.Auth.strategy(spec)

      # A leading path prefix shared by every operation (e.g. `/v3`) is
      # stripped from the operation paths and folded into Layer 1's base
      # URL — see `Hearth.Render.Layer1` for the base-URL side.
      prefix = BasePath.common_prefix(operations)
      selected = BasePath.strip(selected, prefix)

      # Each entry carries a location kind: `:source_folder` writes into
      # `lib/`, `:test` into `test/` (the test module's `Test` suffix
      # routes it there via `Igniter.Project.Module.proper_location/3`).
      sources = [
        {layer1, Hearth.Render.Layer1.render(layer1, otp_app, base_url(spec), prefix, auth),
         "raw Req client", :source_folder},
        {layer2,
         Hearth.Render.Layer2.render(layer2, selected,
           metadata: spec_metadata(path, spec),
           otp_app: otp_app
         ),
         "behaviour, #{length(selected)} #{pluralize("callback", length(selected))}",
         :source_folder},
        {layer3, Hearth.Render.Layer3.render(layer3, layer2, layer1, selected),
         "Req implementation, #{length(selected)} #{pluralize("function", length(selected))}",
         :source_folder},
        {layer1_test, Hearth.Render.Tests.layer1(layer1_test, layer1, otp_app, auth),
         "Layer 1 auth test", :test}
      ]

      written =
        Enum.map(sources, fn {module, source, label, kind} ->
          location = Igniter.Project.Module.proper_location(igniter, module, kind)
          {module, location, source, label}
        end)

      igniter
      # The generated Layer 1/3 reference Req at runtime. `req` rides
      # into Hearth only transitively via the optional, dev-time
      # `igniter` dep, so the consuming app needs it as a direct
      # dependency of its own. Added here rather than in
      # `hearth.install` because it is the *generated code* that needs
      # it. `on_exists: :skip` leaves a consumer's existing `req`
      # untouched — no prompt, no overwrite.
      #
      # `plug` (for the generated Layer 1 test) is deliberately NOT
      # added: `req` already declares it as an optional all-environment
      # dependency, so a consumer dep scoped `only: :test` would diverge
      # and break the build. The test self-guards on
      # `Code.ensure_loaded?(Plug.Conn)` instead.
      |> Igniter.Project.Deps.add_dep({:req, "~> 0.5"}, on_exists: :skip)
      |> write_files(written)
      |> Igniter.add_notice(
        generated_notice(
          path,
          spec,
          operations,
          selected,
          Enum.map(written, fn {module, location, _source, label} ->
            {module, location, label}
          end)
        )
      )
    end

    defp write_files(igniter, written) do
      Enum.reduce(written, igniter, fn {_module, location, source, _label}, acc ->
        Igniter.create_new_file(acc, location, source, on_exists: :overwrite)
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

    # TODO (multi-server): a spec's `servers` may list several URLs;
    # this takes only the first. Planned: Layer 1 renders
    # `@default_base_url` (the first server) always, plus `@base_urls`
    # (the full list) when there is more than one; the client reads a
    # `:base_url` config override alongside `:api_key`; and the
    # generated `config/runtime.exs` raises in prod when the base URL
    # must be picked explicitly.
    defp base_url(spec) do
      case spec |> Map.get("servers", []) |> List.first() do
        %{"url" => url} when is_binary(url) -> url
        _ -> nil
      end
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
        {:halt,
         tag_discovery(operations,
           source: igniter.args.positional[:source],
           integration: igniter.args.options[:integration],
           limit: limit
         )}
      end
    end

    defp resolve_selection(_igniter, operations, tag_values) do
      with {:ok, filter} <- Filter.parse(tag_values),
           [_first | _rest] = selected <- Filter.apply(operations, filter) do
        {:ok, selected}
      else
        {:error, reason} ->
          {:halt, "hearth.gen: #{reason}"}

        [] ->
          {:halt,
           "hearth.gen: no operations matched the --tag filter. " <>
             "Run `mix hearth.gen <source> --list` to see the available tags."}
      end
    end

    # Metadata threaded into the Layer 2 moduledoc footer: the source
    # the spec came from, plus its `info` fields.
    defp spec_metadata(source, spec) do
      %{
        source: source,
        title: get_in(spec, ["info", "title"]),
        version: get_in(spec, ["info", "version"]),
        openapi: spec["openapi"],
        description: get_in(spec, ["info", "description"])
      }
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

    defp generated_notice(path, spec, operations, selected, layers) do
      summary = summarize(spec)
      tag_count = selected |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> length()

      file_lines =
        Enum.map_join(layers, "\n", fn {module, location, label} ->
          "* generating #{location}\n      #{inspect(module)} — #{label}"
        end)

      """
      Spec loaded from #{path}.

          #{summary.title} (info.version #{summary.info_version}, OpenAPI #{summary.openapi})

      Selected #{length(selected)} of #{length(operations)} operations \
      across #{tag_count} #{pluralize("tag", tag_count)}.

      #{file_lines}

      Set the integration's credential in config, then run the generated
      Layer 1 test to confirm the auth scheme works.
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

    # Builds the tag-discovery text: a header, the per-tag operationId
    # listing, and a fully-expanded subset command — every tag with
    # every one of its operationIds spelled out, one `--tag` per line.
    # The user copies it and deletes whole lines or individual
    # operationIds; nothing has to be looked up, no intent is assumed.
    #
    # Shared by the `--n-operations` gate (pass `:limit`) and
    # `mix hearth.gen <file> --list` (pass `limit: nil`).
    defp tag_discovery(operations, opts) do
      source = opts[:source]
      integration = opts[:integration] || "<Name>"
      index = Operation.tag_index(operations)
      total = length(operations)
      tag_count = index |> Map.keys() |> Enum.count(&is_binary/1)

      """
      #{discovery_header(total, tag_count, opts[:limit])}

      Tags in this spec — pass a subset with one or more --tag flags:

      #{format_tag_listing(index)}

      Generate a subset — copy this and delete the --tag lines or the
      operationIds you don't want:

      #{subset_command(source, integration, index)}

      Or generate everything:
        mix hearth.gen #{source} --integration #{integration} --n-operations #{total}
      """
    end

    defp discovery_header(total, tag_count, nil) do
      "This spec has #{total} operations across #{tag_count} #{pluralize("tag", tag_count)}."
    end

    defp discovery_header(total, _tag_count, limit) do
      "This spec has #{total} operations, above the --n-operations limit (#{limit})."
    end

    defp format_tag_listing(index) do
      index
      |> Enum.sort_by(&tag_sort_key/1)
      |> Enum.map_join("\n", &tag_listing_line/1)
    end

    defp subset_command(source, integration, index) do
      tag_lines =
        index
        |> Enum.filter(fn {tag, _ops} -> is_binary(tag) end)
        |> Enum.sort_by(fn {tag, _ops} -> tag end)
        |> Enum.map(fn {tag, ops} ->
          ids = Enum.map_join(ops, ",", & &1.id)
          ~s(    --tag "#{tag}:#{ids}")
        end)

      ["  mix hearth.gen #{source} --integration #{integration}" | tag_lines]
      |> Enum.join(" \\\n")
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
