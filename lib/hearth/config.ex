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
  # (see `load/1`). The file is evaluated like `.formatter.exs`. Pure: the Igniter side
  # (reading through Rewrite, writing entries) is `Hearth.Config.Project`.

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
    with {:ok, term} <- evaluate(content),
         {:ok, integrations} <- integrations(term),
         {:ok, registry} <- registry(term) do
      {:ok, %{integrations: integrations, registry: registry}}
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

  @spec source(entry()) :: String.t() | nil
  def source(entry), do: string(entry[:source])

  @spec base_path(entry()) :: String.t() | nil
  def base_path(entry), do: string(entry[:base_path])

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp evaluate(content) do
    {term, _binding} = Code.eval_string(content, [], file: @path)
    {:ok, term}
  rescue
    error -> {:error, "#{@path} could not be evaluated: #{Exception.message(error)}"}
  end

  # `integrations/1` has already checked `term` is a keyword list.
  defp registry(nil), do: {:ok, %{}}

  defp registry(term) do
    registry = Keyword.get(term, :registry, %{})

    if valid_registry?(registry) do
      {:ok, Map.new(registry, fn {name, versions} -> {String.downcase(name), versions} end)}
    else
      {:error,
       "#{@path}: `registry:` must be a map of name → %{version => URL or file path}, " <>
         ~s|e.g. `registry: %{"acme_api" => %{"1.3" => "https://…/openapi.json", "latest" => {:alias, "1.3"}}}`.|}
    end
  end

  defp valid_registry?(registry) when is_map(registry) do
    Enum.all?(registry, fn {name, versions} ->
      is_binary(name) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.\-]*$/, name) and
        is_map(versions) and Enum.all?(versions, &valid_version?/1)
    end)
  end

  defp valid_registry?(_registry), do: false

  defp valid_version?({version, location}) when is_binary(version) and is_binary(location),
    do: true

  defp valid_version?({version, {:alias, target}}) when is_binary(version) and is_binary(target),
    do: true

  defp valid_version?(_version), do: false

  defp integrations(nil), do: {:ok, []}

  defp integrations(term) do
    with true <- Keyword.keyword?(term) || :not_keyword,
         integrations = Keyword.get(term, :integrations, []),
         true <- valid_integrations?(integrations) || :bad_integrations do
      {:ok, integrations}
    else
      :not_keyword ->
        {:error, "#{@path} must evaluate to a keyword list, got: #{inspect(term)}"}

      :bad_integrations ->
        {:error,
         "#{@path}: `integrations:` must be a keyword list of keyword lists, " <>
           "e.g. `[integrations: [stripe: [module: MyApp.Integrations.Stripe]]]`."}
    end
  end

  defp valid_integrations?(integrations) do
    Keyword.keyword?(integrations) and
      Enum.all?(integrations, fn {_key, entry} -> Keyword.keyword?(entry) end)
  end
end
