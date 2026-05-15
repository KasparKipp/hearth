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

        mix hearth.gen <source> [--integration <Name>] [--domain <Name>] [--refresh] [--yes]

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
      `stripe` is shorthand for `stripe@latest`. Historic versions are
      added to the registry as their spec URLs are confirmed; until then
      only `@latest` is available. The default integration module name
      is derived from the shortcut via `Macro.camelize/1`
      (`stripe → Stripe`, `google_docs → GoogleDocs`) — override with
      `--integration <Name>` when you want something different.

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
      * `--yes` — non-interactive mode. Skips the prompt to run
        `mix hearth.install` on a fresh project and accepts any other
        confirmations.

    ## Pipeline status

      * Available now — source recognition (URL / file / registry),
        registry lookup, file-existence validation, install gating.
      * Coming soon — YAML/JSON decode, on-disk cache, HTTP fetcher,
        code generation.

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

    alias Hearth.Spec.Source

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :hearth,
        schema: [
          integration: :string,
          domain: :string,
          refresh: :boolean,
          yes: :boolean
        ],
        positional: [:source],
        installs: [],
        example: __MODULE__.Docs.example()
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      case ensure_installed(igniter) do
        {:ok, igniter} -> dispatch_source(igniter)
        {:halt, igniter} -> igniter
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
          if Igniter.exists?(igniter, path) do
            Igniter.add_notice(igniter, file_notice(path))
          else
            Igniter.add_issue(
              igniter,
              "hearth.gen: file not found at #{inspect(path)}. " <>
                "Check the path is correct and relative to the project root."
            )
          end

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

    defp file_notice(path) do
      """
      Source recognized: file.

          #{path}

      Next pipeline stage: YAML/JSON decode. Not yet wired — when ready,
      this command will read and decode the spec before generating an
      integration.
      """
    end

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
      available = Hearth.Registry.list() |> Enum.map(&"  * #{&1}") |> Enum.join("\n")

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
      versions_block = available |> Enum.map(&"  * #{name}@#{&1}") |> Enum.join("\n")

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
