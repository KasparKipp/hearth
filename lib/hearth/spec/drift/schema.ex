defmodule Hearth.Spec.Drift.Schema do
  @moduledoc false

  # Compares two versions of a JSON schema, as found in an OpenAPI spec,
  # and lists what changed as `{detail, breaking?}`. Only shape counts —
  # `description`, `example`, `title` and other annotations are ignored.
  #
  # Whether a change breaks depends on the schema's side: a schema sent
  # in requests breaks callers when it accepts less (tighter), one read
  # in responses breaks them when it may return more (looser), one used
  # on both sides breaks either way. Each change has an effect —
  # `:request` (tighter), `:response` (looser), `:both` or `:none`:
  #
  #   * properties: optional one added (none), required one added or
  #     now required (tighter), no longer required (looser), removed
  #     (both)
  #   * `enum`: values gained or the enum dropped (looser), values lost
  #     or an enum added (tighter); compared as sets
  #   * `type`, as a set without `"null"`: narrower or added (tighter),
  #     wider or dropped (looser), else both. Nullability — 3.0
  #     `nullable` or 3.1 `"null"` in `type`, alike — lost (tighter) or
  #     gained (looser)
  #   * `$ref` changes (both) — a `$ref` target's own changes are
  #     reported under that component
  #   * `items` and `allOf` / `oneOf` / `anyOf` members (by position) are
  #     compared recursively; a member count change is both
  #
  # Nested changes carry their path: `owner.name`, `tags[]`, `allOf[1]`.

  @compositions ~w(allOf oneOf anyOf)

  @type side :: :request | :response | :both
  @type effect :: :request | :response | :both | :none

  @spec changes(term(), term(), side()) :: [{String.t(), boolean()}]
  def changes(old, new, side \\ :request) do
    for {detail, effect} <- walk("", old, new), do: {detail, breaking?(effect, side)}
  end

  @spec breaking?(effect(), side()) :: boolean()
  def breaking?(:none, _side), do: false
  def breaking?(:both, _side), do: true
  def breaking?(_effect, :both), do: true
  def breaking?(effect, side), do: effect == side

  defp walk(_path, same, same), do: []

  defp walk(path, %{} = old, %{} = new) do
    if Map.has_key?(old, "$ref") or Map.has_key?(new, "$ref") do
      ref(path, old["$ref"], new["$ref"])
    else
      type(path, old, new) ++
        nullable(path, old, new) ++
        enum(path, old, new) ++
        properties(path, old, new) ++
        required(path, old, new) ++
        items(path, old, new) ++
        Enum.flat_map(@compositions, &composition(path, &1, old[&1], new[&1]))
    end
  end

  defp walk(path, _old, _new), do: [at(path, "schema changed", :both)]

  defp ref(_path, same, same), do: []

  defp ref(path, old, new),
    do: [at(path, "$ref #{ref_name(old)} → #{ref_name(new)}", :both)]

  defp ref_name(nil), do: "(inline)"
  defp ref_name(ref), do: ref |> String.split("/") |> List.last()

  # `type` without `"null"`, as a set; an empty set is no type at all.
  defp type(path, old, new) do
    {old_types, new_types} = {types(old), types(new)}
    {old_set, new_set} = {MapSet.new(old_types), MapSet.new(new_types)}

    if old_set == new_set,
      do: [],
      else: [
        at(
          path,
          "type #{type_name(old_types)} → #{type_name(new_types)}",
          widening(old_set, new_set)
        )
      ]
  end

  defp types(schema), do: schema["type"] |> List.wrap() |> Enum.reject(&(&1 == "null"))

  defp widening(old, new) do
    cond do
      MapSet.size(old) == 0 -> :request
      MapSet.size(new) == 0 -> :response
      MapSet.subset?(new, old) -> :request
      MapSet.subset?(old, new) -> :response
      true -> :both
    end
  end

  defp type_name([]), do: "(none)"
  defp type_name(types), do: Enum.map_join(types, " | ", &to_string/1)

  defp nullable(path, old, new) do
    case {nullable?(old), nullable?(new)} do
      {same, same} -> []
      {true, false} -> [at(path, "no longer nullable", :request)]
      {false, true} -> [at(path, "now nullable", :response)]
    end
  end

  defp nullable?(schema), do: schema["nullable"] == true or "null" in List.wrap(schema["type"])

  defp enum(path, old, new) do
    case {old["enum"], new["enum"]} do
      {same, same} -> []
      {nil, values} -> [at(path, "enum (none) → #{values(values)}", :request)]
      {values, nil} -> [at(path, "enum #{values(values)} → (none)", :response)]
      {old_values, new_values} -> enum_values(path, old_values, new_values)
    end
  end

  defp enum_values(path, old, new) do
    gained = new |> Enum.uniq() |> Enum.reject(&(&1 in old))
    lost = old |> Enum.uniq() |> Enum.reject(&(&1 in new))

    if(gained == [], do: [], else: [at(path, "enum gains #{values(gained)}", :response)]) ++
      if lost == [], do: [], else: [at(path, "enum loses #{values(lost)}", :request)]
  end

  defp values(values), do: values |> List.wrap() |> Enum.map_join(", ", &text/1)

  # A keyword's value as it reads in a detail line.
  @spec text(term()) :: String.t()
  def text(nil), do: "(none)"
  def text(value) when is_binary(value), do: value
  def text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def text(value), do: JSON.encode!(value)

  defp properties(path, old, new) do
    old_props = old["properties"] || %{}
    new_props = new["properties"] || %{}
    new_required = List.wrap(new["required"])

    added =
      for name <- sorted_keys(new_props), not Map.has_key?(old_props, name) do
        if name in new_required,
          do: at(path, "property #{name} added, required", :request),
          else: at(path, "property #{name} added", :none)
      end

    removed =
      for name <- sorted_keys(old_props), not Map.has_key?(new_props, name) do
        at(path, "property #{name} removed", :both)
      end

    nested =
      for name <- sorted_keys(old_props),
          Map.has_key?(new_props, name),
          change <- walk(join(path, name), old_props[name], new_props[name]),
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
        do: at(path, "#{name} is now required", :request),
        else: at(path, "#{name} is no longer required", :response)
    end
  end

  defp items(path, old, new) do
    case {old["items"], new["items"]} do
      {nil, nil} -> []
      {old_items, new_items} -> walk(path <> "[]", old_items, new_items)
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
      |> Enum.flat_map(fn {{o, n}, i} -> walk(join(path, "#{key}[#{i}]"), o, n) end)
    else
      [at(path, "#{key}: #{length(old)} → #{length(new)} schemas", :both)]
    end
  end

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()

  defp join("", name), do: name
  defp join(path, name), do: path <> "." <> name

  defp at("", detail, effect), do: {detail, effect}
  defp at(path, detail, effect), do: {"#{path}: #{detail}", effect}
end
