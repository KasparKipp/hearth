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
    alias Hearth.Spec.Auth
    alias Hearth.Spec.Loader
    alias Hearth.Spec.Operation
    alias Hearth.Spec.Overrides
    alias Hearth.Spec.PrefixedIds
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
            stale_overrides: [Overrides.stale()],
            auth: keyword(),
            splits: [Hearth.Spec.Merge.component()],
            source_keys: [atom()]
          }

    @type reason ::
            :no_tags
            | {:bad_tags, String.t()}
            | {:bad_overrides, String.t()}
            | {:bad_auth, term(), [String.t()]}
            | {:bad_prefixed_ids, String.t()}
            | :no_source
            | :empty_selection
            | :source_for_sources
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
           :ok <- single_override(opts[:source], entry),
           {:ok, overrides} <- overrides(entry),
           {:ok, igniter, loaded} <-
             Load.load(igniter, source, opts[:registry] || %{}, overrides.shared),
           {:ok, spec, stale} <- apply_overrides(loaded.spec, overrides),
           {:ok, spec, auth} <- Auth.choose(spec, entry),
           {:ok, prefixed} <- prefixed_ids(spec, entry),
           operations = Operation.extract(spec),
           rule = carry_renames(rule, opts[:current], operations),
           [_ | _] = selected <- Selection.select(operations, rule) do
        yaml = spec |> Prune.prune(selected ++ targets(operations, prefixed)) |> Prune.to_yaml()
        {:ok, pruned} = Loader.decode(yaml, :yaml)

        {:ok, igniter,
         %{
           source: label(source),
           sha256: loaded.sha256,
           operations: operations,
           rule: rule,
           selected: selected,
           yaml: yaml,
           pruned: pruned,
           stale_overrides: stale,
           auth: auth,
           splits: loaded.splits,
           source_keys: source_keys(source)
         }}
      else
        [] -> {:error, label(source), :empty_selection}
        {:error, reason} -> {:error, label(source), reason}
      end
    end

    @spec sha256(binary()) :: String.t()
    defdelegate sha256(bytes), to: Load

    defp carry_renames(rule, nil, _operations), do: rule

    defp carry_renames(rule, current, operations),
      do: Selection.carry_renames(rule, Operation.extract(current), operations)

    defp apply_overrides(spec, overrides) do
      case Overrides.apply(spec, overrides) do
        {:ok, spec, stale} -> {:ok, spec, stale}
        {:error, detail} -> {:error, {:bad_overrides, detail}}
      end
    end

    defp prefixed_ids(spec, entry) do
      case PrefixedIds.prepare(spec, entry) do
        {:ok, prefixed} -> {:ok, prefixed}
        {:error, detail} -> {:error, {:bad_prefixed_ids, detail}}
      end
    end

    # The operations `prefixed_ids:` functions call, kept in the pruned
    # spec beside the selected ones.
    defp targets(_operations, nil), do: []

    defp targets(operations, prefixed),
      do: PrefixedIds.targets(operations, prefixed.resources, prefixed.functions)

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

    # `--source` names one spec; it can't stand in for several.
    defp single_override(nil, _entry), do: :ok

    defp single_override(_source, entry),
      do: if(is_list(Config.source(entry)), do: {:error, :source_for_sources}, else: :ok)

    defp source_keys(sources) when is_list(sources), do: Keyword.keys(sources)
    defp source_keys(_source), do: []

    # `sources:` components the pruned spec has under their plain name
    # that the merge now splits per source, each with the source whose
    # copy still matches — the one to pin with `overrides: [shared: …]`.
    @spec splits(result(), map()) :: [{Hearth.Spec.Merge.component(), atom()}]
    def splits(result, current) do
      for {section, name} <- result.splits,
          plain = get_in(current, ["components", section, name]),
          not is_nil(plain) do
        keeper =
          Enum.find(result.source_keys, hd(result.source_keys), fn key ->
            get_in(result.pruned, ["components", section, "#{key}_#{name}"]) == plain
          end)

        {{section, name}, keeper}
      end
    end

    defp label(nil), do: nil
    defp label(source), do: Config.source_label(source)

    defp present(nil), do: {:error, :no_source}
    defp present(source), do: {:ok, source}
  end
end
