if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Integration.Reprune do
    @moduledoc false

    # Re-prunes an integration's spec from a source with the selection
    # its `.hearth.exs` `tags:` declare. `regen --sync` writes the result;
    # `mix hearth.diff` compares it with the pruned spec. The source is
    # the entry's `source:` unless the caller passes another — any source
    # `Hearth.Integration.Load` reads: a file, a URL, or a shortcut. Given the current pruned spec, upstream
    # operationId renames are carried into the rule first
    # (`Selection.carry_renames/3`), so a renamed operation stays selected. Errors are reasons for
    # `Hearth.Integration.Messages.reprune_message/5`.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config
    alias Hearth.Integration.Load
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Overrides
    alias Hearth.Spec.Prune
    alias Hearth.Spec.Selection

    @type result :: %{
            source: String.t(),
            sha256: String.t(),
            operations: [Operation.t()],
            rule: Selection.rule(),
            selected: [Operation.t()],
            yaml: String.t(),
            pruned: map(),
            stale_overrides: [Overrides.stale()]
          }

    @type reason ::
            :no_tags
            | {:bad_tags, String.t()}
            | {:bad_overrides, String.t()}
            | :no_source
            | :empty_selection
            | Load.reason()

    # Options: `:source` — another source to re-prune instead of the
    # entry's; `:current` — the pruned spec, so upstream renames are
    # carried into `tags:`; `:registry` — the project's `.hearth.exs`
    # registry, for shortcuts.
    @spec run(Igniter.t(), Config.entry(), keyword()) ::
            {:ok, Igniter.t(), result()} | {:error, String.t() | nil, reason()}
    def run(igniter, entry, opts \\ []) do
      source = opts[:source] || Config.source(entry)

      with {:ok, rule} <- rule(entry),
           {:ok, source} <- present(source),
           {:ok, overrides} <- overrides(entry),
           {:ok, igniter, loaded} <- Load.load(igniter, source, opts[:registry] || %{}),
           {spec, stale} = Overrides.apply(loaded.spec, overrides),
           operations = Operation.extract(spec),
           rule = carry_renames(rule, opts[:current], operations),
           [_ | _] = selected <- Selection.select(operations, rule) do
        yaml = spec |> Prune.prune(selected) |> Prune.to_yaml()
        {:ok, pruned} = Loader.decode(yaml, :yaml)

        {:ok, igniter,
         %{
           source: source,
           sha256: sha256(loaded.bytes),
           operations: operations,
           rule: rule,
           selected: selected,
           yaml: yaml,
           pruned: pruned,
           stale_overrides: stale
         }}
      else
        [] -> {:error, source, :empty_selection}
        {:error, reason} -> {:error, source, reason}
      end
    end

    @spec sha256(binary()) :: String.t()
    def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    defp carry_renames(rule, nil, _operations), do: rule

    defp carry_renames(rule, current, operations),
      do: Selection.carry_renames(rule, Operation.extract(current), operations)

    defp overrides(entry) do
      case Overrides.parse(entry) do
        {:ok, overrides} -> {:ok, overrides}
        {:error, detail} -> {:error, {:bad_overrides, detail}}
      end
    end

    defp rule(entry) do
      case Selection.rule(entry) do
        {:ok, rule} -> {:ok, rule}
        :none -> {:error, :no_tags}
        {:error, detail} -> {:error, {:bad_tags, detail}}
      end
    end

    defp present(nil), do: {:error, :no_source}
    defp present(source), do: {:ok, source}
  end
end
