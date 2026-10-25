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
  # The file is evaluated like `.formatter.exs`. Pure: the Igniter side
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
    with {:ok, term} <- evaluate(content) do
      integrations(term)
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
