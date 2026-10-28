defmodule Hearth.Config do
  @moduledoc false

  # `.hearth.exs` at the project root: one entry per integration,
  # keyed by its snake_case name. `mix hearth.gen` writes the entry;
  # `mix hearth.regen` reads it back so regeneration reproduces gen's
  # choices instead of recomputing them from the pruned spec:
  #
  #     [
  #       integrations: [
  #         stripe: [
  #           module: MyApp.Integrations.Stripe,
  #           source: "priv/specs/stripe.yaml",
  #           base_path: "/v1"
  #         ]
  #       ]
  #     ]
  #
  #   * `module` — the Layer 1 module. Every other module derives from
  #     it, so the domain gen chose survives.
  #   * `source` — the spec gen ran on, shown in Layer 2's moduledoc.
  #   * `base_path` — the path prefix folded into Layer 1's base URL
  #     (and `config/test.exs`). Recomputed from the pruned subset, it
  #     can come out longer and desync from that config.
  #
  # An optional `registry:` declares the project's own source shortcuts
  # (see `load/1`). The file is read as data (`Hearth.Config.Literal` —
  # parsed, never evaluated), then validated against
  # `Hearth.Config.Schema`. Pure: the Igniter side (reading through
  # Rewrite, writing entries) is `Hearth.Config.Project`.

  alias Hearth.Config.Literal
  alias Hearth.Config.Schema
  alias Hearth.Render.ModuleNames

  @path ".hearth.exs"

  @type entry :: keyword()
  @type integrations :: [{atom(), entry()}]

  @spec path() :: String.t()
  def path, do: @path

  @spec template() :: String.t()
  def template do
    """
    # Hearth integrations: `mix hearth.gen` adds one entry per
    # integration, and `mix hearth.regen` reads it.
    [integrations: []]
    """
  end

  @spec parse(binary()) :: {:ok, integrations()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    with {:ok, %{integrations: integrations}} <- load(content), do: {:ok, integrations}
  end

  # The whole file: the integrations and the project's own registry —
  # `%{name => %{version => location | {:alias, version}}}`, the shape
  # of `Hearth.Registry`'s built-in entries, which a local name shadows.
  # Names are lowercased, like registry sources are.
  @spec load(binary()) ::
          {:ok, %{integrations: integrations(), registry: map()}} | {:error, String.t()}
  def load(content) when is_binary(content) do
    with {:ok, term} <- Literal.read(content, @path),
         {:ok, term} <- keyword(term),
         :ok <- Schema.validate(term) do
      {:ok, %{integrations: Keyword.get(term, :integrations, []), registry: registry(term)}}
    end
  end

  # The `.hearth.exs` key for an integration name: `"SendGrid"` and
  # `"send_grid"` both → `:send_grid`.
  @spec key(String.t()) :: atom()
  def key(name) when is_binary(name) do
    name |> Macro.camelize() |> Macro.underscore() |> String.to_atom()
  end

  # The entry's Layer 1 module, or `{:error, value}` when it isn't a
  # module alias (a string, a plain atom, missing).
  @spec module(entry()) :: {:ok, module()} | {:error, term()}
  def module(entry) do
    value = entry[:module]

    with true <- is_atom(value) and not is_nil(value),
         {:ok, module} <- ModuleNames.parse(Atom.to_string(value)),
         true <- module == value do
      {:ok, module}
    else
      _ -> {:error, value}
    end
  end

  # The entry's source: `source:` (a string), or `sources:` — several
  # specs merged into one integration (`Hearth.Spec.Merge`), as a
  # keyword list of short name → source.
  @type source :: String.t() | [{atom(), String.t()}]

  @spec source(entry()) :: source() | nil
  def source(entry), do: entry[:sources] || entry[:source]

  # A source as the user reads it: `items: a.json, orders: b.json`.
  @spec source_label(source()) :: String.t()
  def source_label(sources) when is_list(sources),
    do: Enum.map_join(sources, ", ", fn {key, source} -> "#{key}: #{source}" end)

  def source_label(source), do: source

  @spec base_path(entry()) :: String.t() | nil
  def base_path(entry), do: entry[:base_path]

  # The project's own registry, its names lowercased like registry
  # sources are.
  defp registry(term) do
    term
    |> Keyword.get(:registry, %{})
    |> Map.new(fn {name, versions} -> {String.downcase(name), versions} end)
  end

  defp keyword(nil), do: {:ok, []}

  defp keyword(term) do
    if Keyword.keyword?(term),
      do: {:ok, term},
      else: {:error, "#{@path} must hold a keyword list, got: #{inspect(term)}"}
  end
end
