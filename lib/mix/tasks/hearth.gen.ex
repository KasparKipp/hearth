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

        mix hearth.gen <source> [--integration <Name>] [--domain <Name>] [--refresh]

    ## Source modes

        # Local file
        mix hearth.gen priv/specs/petstore.yaml --integration Petstore

        # URL
        mix hearth.gen https://example.com/openapi.json --integration Acme

        # Registry (curated shorthand — not yet wired)
        mix hearth.gen <name>

    ## Pipeline status

      * Available now — source recognition (URL / file / registry).
      * Coming soon — registry lookup, YAML/JSON decode, on-disk cache,
        HTTP fetcher, code generation.
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
      source = igniter.args.positional[:source]

      case Source.resolve(source) do
        {:url, url} ->
          Igniter.add_notice(igniter, url_notice(url))

        {:file, path} ->
          Igniter.add_notice(igniter, file_notice(path))

        {:registry, name} ->
          Igniter.add_notice(igniter, registry_notice(name))

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

    defp registry_notice(name) do
      """
      Source recognized: registry shorthand `#{name}`.

      Next pipeline stage: registry lookup. Not yet wired — no curated
      entries are resolvable yet. When ready, registry names will resolve
      to canonical OpenAPI URLs maintained by the Hearth project and
      fetch through the same cache as bare URLs.
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
