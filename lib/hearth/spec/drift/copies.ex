defmodule Hearth.Spec.Drift.Copies do
  @moduledoc false

  # A `sources:` merge names a component's per-source copies
  # `<key>_<name>` (`Hearth.Spec.Merge`). Pairs the copies in one pruned
  # spec with the plain name in the other, so drift can report a split
  # or join instead of a removal plus additions:
  #
  #   * split — copies in the newer spec of a name the merge split
  #     (`merge: [splits:]`), where the older spec has the plain name
  #     and not the copy
  #   * join — copies in the older spec, where the newer has the plain
  #     name and not the copy. The older spec doesn't record its
  #     splits, so this goes by name, longest source key first.
  #
  # Pure. Schemas only: drift compares other components through the
  # operations that reference them, which follow refs.

  # `%{copy => {source key, plain name}}`
  @type pairs :: %{String.t() => {atom(), String.t()}}

  @spec pairs(map(), map(), keyword()) :: {splits :: pairs(), joins :: pairs()}
  def pairs(current, candidate, merge) do
    keys = Keyword.get(merge, :keys, [])
    old = schemas(current)
    new = schemas(candidate)

    splits =
      for {"schemas", plain} <- Keyword.get(merge, :splits, []),
          Map.has_key?(old, plain),
          key <- keys,
          copy = "#{key}_#{plain}",
          Map.has_key?(new, copy) and not Map.has_key?(old, copy),
          into: %{},
          do: {copy, {key, plain}}

    longest_first = Enum.sort_by(keys, &String.length(Atom.to_string(&1)), :desc)

    joins =
      for name <- Map.keys(old),
          not Map.has_key?(new, name),
          pair = join(name, longest_first, new),
          into: %{},
          do: {name, pair}

    {splits, joins}
  end

  @spec schemas(map()) :: map()
  def schemas(spec), do: get_in(spec, ["components", "schemas"]) || %{}

  # Points `$ref`s to a paired copy at its plain name, so a ref that only
  # moved to a copy doesn't count as changed.
  @spec plain_refs(map(), pairs()) :: map()
  def plain_refs(spec, pairs) when pairs == %{}, do: spec

  def plain_refs(spec, pairs) do
    rewrite_refs(spec, Map.new(pairs, fn {copy, {_key, plain}} -> {ref(copy), ref(plain)} end))
  end

  defp join(name, keys, new) do
    Enum.find_value(keys, fn key ->
      plain = String.replace_prefix(name, "#{key}_", "")
      if plain != name and Map.has_key?(new, plain), do: {key, plain}
    end)
  end

  defp ref(name), do: "#/components/schemas/" <> name

  defp rewrite_refs(%{"$ref" => ref} = map, refs) when is_map_key(refs, ref),
    do: Map.put(map, "$ref", Map.fetch!(refs, ref))

  defp rewrite_refs(map, refs) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, rewrite_refs(v, refs)} end)

  defp rewrite_refs(list, refs) when is_list(list), do: Enum.map(list, &rewrite_refs(&1, refs))
  defp rewrite_refs(value, _refs), do: value
end
