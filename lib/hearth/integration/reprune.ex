if Code.ensure_loaded?(Igniter) do
  defmodule Hearth.Integration.Reprune do
    @moduledoc false

    # Re-prunes an integration's spec from a source with the selection
    # its `.hearth.exs` `tags:` declare. `regen --sync` writes the result;
    # `mix hearth.diff` compares it with the pruned spec. The source is
    # the entry's `source:` unless the caller passes another; only local
    # spec files are read today. Given the current pruned spec, upstream
    # operationId renames are carried into the rule first
    # (`Selection.carry_renames/3`), so a renamed operation stays selected. Errors are reasons for
    # `Hearth.Integration.Messages.reprune_message/4`.
    #
    # Guarded like the Mix tasks: Igniter is an optional dependency.

    alias Hearth.Config
    alias Hearth.Fs.Content
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Prune
    alias Hearth.Spec.Selection
    alias Hearth.Spec.Source

    @type result :: %{
            source: String.t(),
            sha256: String.t(),
            operations: [Operation.t()],
            rule: Selection.rule(),
            selected: [Operation.t()],
            yaml: String.t(),
            pruned: map()
          }

    @type reason ::
            :no_tags
            | {:bad_tags, String.t()}
            | :no_source
            | :not_local
            | :missing
            | :unsupported
            | {:decode, term()}
            | :empty_selection

    @spec run(Igniter.t(), Config.entry(), String.t() | nil, map() | nil) ::
            {:ok, Igniter.t(), result()} | {:error, String.t() | nil, reason()}
    def run(igniter, entry, source \\ nil, current \\ nil) do
      source = source || Config.source(entry)

      with {:ok, rule} <- rule(entry),
           {:ok, path} <- local_path(source),
           {:ok, igniter, spec} <- read(igniter, path),
           {:ok, bytes} <- Content.read(igniter, path),
           operations = Operation.extract(spec),
           rule = carry_renames(rule, current, operations),
           [_ | _] = selected <- Selection.select(operations, rule) do
        yaml = spec |> Prune.prune(selected) |> Prune.to_yaml()
        {:ok, pruned} = Loader.decode(yaml, :yaml)

        {:ok, igniter,
         %{
           source: source,
           sha256: sha256(bytes),
           operations: operations,
           rule: rule,
           selected: selected,
           yaml: yaml,
           pruned: pruned
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

    defp rule(entry) do
      case Selection.rule(entry) do
        {:ok, rule} -> {:ok, rule}
        :none -> {:error, :no_tags}
        {:error, detail} -> {:error, {:bad_tags, detail}}
      end
    end

    defp local_path(nil), do: {:error, :no_source}

    defp local_path(source) do
      case Source.resolve(source) do
        {:file, path} -> {:ok, path}
        _url_or_registry -> {:error, :not_local}
      end
    end

    defp read(igniter, path) do
      case Content.read_spec(igniter, path) do
        {:ok, igniter, spec} -> {:ok, igniter, spec}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
