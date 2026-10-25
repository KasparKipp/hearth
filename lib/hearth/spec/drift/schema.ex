defmodule Hearth.Spec.Drift.Schema do
  @moduledoc false

  # Compares two versions of a JSON schema, as found in an OpenAPI spec,
  # and lists what changed as `{detail, breaking?}`. Only shape counts —
  # `description`, `example`, `title` and other annotations are ignored.
  #
  #   * properties: added (breaking only when also required), removed
  #     (breaking), newly required (breaking), no longer required
  #   * `enum`: values gained, values lost (breaking)
  #   * `type` and `$ref` changes (breaking) — a `$ref` target's own
  #     changes are reported under that component
  #   * `items` and `allOf` / `oneOf` / `anyOf` members (by position) are
  #     compared recursively; a member count change is breaking
  #
  # Nested changes carry their path: `owner.name`, `tags[]`, `allOf[1]`.

  @compositions ~w(allOf oneOf anyOf)

  @spec changes(term(), term()) :: [{String.t(), boolean()}]
  def changes(old, new), do: changes("", old, new)

  defp changes(_path, same, same), do: []

  defp changes(path, %{} = old, %{} = new) do
    if Map.has_key?(old, "$ref") or Map.has_key?(new, "$ref") do
      ref(path, old["$ref"], new["$ref"])
    else
      type(path, old, new) ++
        enum(path, old, new) ++
        properties(path, old, new) ++
        required(path, old, new) ++
        items(path, old, new) ++
        Enum.flat_map(@compositions, &composition(path, &1, old[&1], new[&1]))
    end
  end

  defp changes(path, _old, _new), do: [at(path, "schema changed", true)]

  defp ref(_path, same, same), do: []

  defp ref(path, old, new),
    do: [at(path, "$ref #{ref_name(old)} → #{ref_name(new)}", true)]

  defp ref_name(nil), do: "(inline)"
  defp ref_name(ref), do: ref |> String.split("/") |> List.last()

  defp type(path, old, new) do
    if old["type"] == new["type"],
      do: [],
      else: [at(path, "type #{type_name(old["type"])} → #{type_name(new["type"])}", true)]
  end

  defp type_name(nil), do: "(none)"
  defp type_name(type) when is_list(type), do: Enum.join(type, " | ")
  defp type_name(type), do: to_string(type)

  defp enum(path, old, new) do
    old_values = List.wrap(old["enum"])
    new_values = List.wrap(new["enum"])
    gained = new_values -- old_values
    lost = old_values -- new_values

    if(gained == [], do: [], else: [at(path, "enum gains #{values(gained)}", false)]) ++
      if lost == [], do: [], else: [at(path, "enum loses #{values(lost)}", true)]
  end

  defp values(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp properties(path, old, new) do
    old_props = old["properties"] || %{}
    new_props = new["properties"] || %{}
    new_required = List.wrap(new["required"])

    added =
      for name <- sorted_keys(new_props), not Map.has_key?(old_props, name) do
        if name in new_required,
          do: at(path, "property #{name} added, required", true),
          else: at(path, "property #{name} added", false)
      end

    removed =
      for name <- sorted_keys(old_props), not Map.has_key?(new_props, name) do
        at(path, "property #{name} removed", true)
      end

    nested =
      for name <- sorted_keys(old_props),
          Map.has_key?(new_props, name),
          change <- changes(join(path, name), old_props[name], new_props[name]),
          do: change

    added ++ removed ++ nested
  end

  # Only properties present in both versions — added and removed ones
  # are reported by `properties/3`.
  defp required(path, old, new) do
    both =
      MapSet.intersection(
        MapSet.new(Map.keys(old["properties"] || %{})),
        MapSet.new(Map.keys(new["properties"] || %{}))
      )

    old_required = MapSet.new(List.wrap(old["required"]))
    new_required = MapSet.new(List.wrap(new["required"]))

    for name <- Enum.sort(both),
        MapSet.member?(old_required, name) != MapSet.member?(new_required, name) do
      if MapSet.member?(new_required, name),
        do: at(path, "#{name} is now required", true),
        else: at(path, "#{name} is no longer required", false)
    end
  end

  defp items(path, old, new) do
    case {old["items"], new["items"]} do
      {nil, nil} -> []
      {old_items, new_items} -> changes(path <> "[]", old_items, new_items)
    end
  end

  defp composition(_path, _key, same, same), do: []

  defp composition(path, key, old, new) do
    old = List.wrap(old)
    new = List.wrap(new)

    if length(old) == length(new) do
      old
      |> Enum.zip(new)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{o, n}, i} -> changes(join(path, "#{key}[#{i}]"), o, n) end)
    else
      [at(path, "#{key}: #{length(old)} → #{length(new)} schemas", true)]
    end
  end

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()

  defp join("", name), do: name
  defp join(path, name), do: path <> "." <> name

  defp at("", detail, breaking?), do: {detail, breaking?}
  defp at(path, detail, breaking?), do: {"#{path}: #{detail}", breaking?}
end
