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
  #     (a nullable schema's `null` value is nullability, not enum)
  #   * `type`, as a set without `"null"`, `number` including
  #     `integer`: narrower or added (tighter), wider or dropped
  #     (looser), else both. Nullability — 3.0 `nullable` or 3.1
  #     `"null"` in `type`, alike — lost (tighter) or gained (looser)
  #   * `$ref` changes (both) — a `$ref` target's own changes are
  #     reported under that component; keywords beside an unchanged
  #     `$ref` (`nullable`, constraints) are compared
  #   * constraint keywords (`maxLength`, `pattern`, `format`, …), by
  #     `Hearth.Spec.Drift.Constraints`
  #   * `additionalProperties` (absent ≡ `true` ≡ `{}`): `true` → a
  #     schema → `false` tightens, the reverse loosens; a schema against
  #     a schema is compared recursively
  #   * `items` added (tighter) or removed (looser); `items` and
  #     `allOf` / `oneOf` / `anyOf` members (by position) are compared
  #     recursively; a member count change is both
  #
  # A `readOnly` property is never sent, so its changes — required,
  # enum, type, constraints — don't count in requests; a `writeOnly`
  # one's don't count in responses. They're still listed.
  #
  # Nested changes carry their path: `owner.name`, `tags[]`, `meta{}`,
  # `allOf[1]`.

  alias Hearth.Spec.Drift.Constraints

  @compositions ~w(allOf oneOf anyOf)

  @type side :: :request | :response | :both
  @type effect :: :request | :response | :both | :none

  @spec changes(term(), term(), side()) :: [{String.t(), boolean()}]
  def changes(old, new, side \\ :request) do
    for {detail, effect} <- walk("", old, new, %{side: side, ignore: nil}),
        do: {detail, breaking?(effect, side)}
  end

  @spec breaking?(effect(), side()) :: boolean()
  def breaking?(:none, _side), do: false
  def breaking?(:both, _side), do: true
  def breaking?(_effect, :both), do: true
  def breaking?(effect, side), do: effect == side

  # `ctx.ignore` — the side whose changes don't count here (inside a
  # `readOnly` or `writeOnly` property), else nil. Such changes are still
  # listed, as drift that breaks nothing.
  defp walk(path, old, new, ctx) do
    for {detail, effect} <- compare(path, old, new, ctx),
        do: {detail, ignoring(effect, ctx.ignore)}
  end

  defp compare(_path, same, same, _ctx), do: []

  defp compare(path, %{} = old, %{} = new, ctx) do
    if old["$ref"] == new["$ref"] do
      type(path, old, new) ++
        nullable(path, old, new) ++
        enum(path, old, new) ++
        constraints(path, old, new) ++
        properties(path, old, new, ctx) ++
        required(path, old, new) ++
        additional(path, old["additionalProperties"], new["additionalProperties"], ctx) ++
        items(path, old, new, ctx) ++
        Enum.flat_map(@compositions, &composition(path, &1, {old[&1], new[&1]}, ctx))
    else
      [at(path, "$ref #{ref_name(old["$ref"])} → #{ref_name(new["$ref"])}", :both)]
    end
  end

  defp compare(path, _old, _new, _ctx), do: [at(path, "schema changed", :both)]

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
    {old, new} = {with_integer(old), with_integer(new)}

    cond do
      old == new -> :none
      MapSet.size(old) == 0 -> :request
      MapSet.size(new) == 0 -> :response
      MapSet.subset?(new, old) -> :request
      MapSet.subset?(old, new) -> :response
      true -> :both
    end
  end

  # Every integer is a number.
  defp with_integer(types),
    do: if("number" in types, do: MapSet.put(types, "integer"), else: types)

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

  # `null` among the values says nothing new when the schema is nullable
  # on both sides — 3.1 lists it, 3.0 `nullable` doesn't — and
  # nullability is compared on its own.
  defp enum(path, old, new) do
    null? = nullable?(old) and nullable?(new)

    case {enum_list(old, null?), enum_list(new, null?)} do
      {same, same} -> []
      {nil, values} -> [at(path, "enum (none) → #{values(values)}", :request)]
      {values, nil} -> [at(path, "enum #{values(values)} → (none)", :response)]
      {old_values, new_values} -> enum_values(path, old_values, new_values)
    end
  end

  defp enum_list(%{"enum" => values}, null?) when is_list(values) do
    values = Enum.map(values, &Constraints.normalize/1)
    if null?, do: Enum.reject(values, &is_nil/1), else: values
  end

  defp enum_list(schema, _null?), do: schema["enum"]

  defp enum_values(path, old, new) do
    gained = new |> Enum.uniq() |> Enum.reject(&(&1 in old))
    lost = old |> Enum.uniq() |> Enum.reject(&(&1 in new))

    if(gained == [], do: [], else: [at(path, "enum gains #{values(gained)}", :response)]) ++
      if lost == [], do: [], else: [at(path, "enum loses #{values(lost)}", :request)]
  end

  defp values(values), do: values |> List.wrap() |> Enum.map_join(", ", &Constraints.text/1)

  defp constraints(path, old, new) do
    for {detail, effect} <- Constraints.changes(old, new), do: at(path, detail, effect)
  end

  # Inside a `readOnly` property of a schema used on both sides only the
  # response counts, and the other way round for `writeOnly`.
  defp ignoring(effect, nil), do: effect
  defp ignoring(ignore, ignore), do: :none
  defp ignoring(:both, :request), do: :response
  defp ignoring(:both, :response), do: :request
  defp ignoring(effect, _ignore), do: effect

  defp properties(path, old, new, ctx) do
    old_props = old["properties"] || %{}
    new_props = new["properties"] || %{}
    new_required = List.wrap(new["required"])

    added =
      for name <- sorted_keys(new_props), not Map.has_key?(old_props, name) do
        new_prop = new_props[name]

        if name in new_required,
          do: at(path, "property #{name} added, required", only(:request, new_prop, new_prop)),
          else: at(path, "property #{name} added", :none)
      end

    removed =
      for name <- sorted_keys(old_props), not Map.has_key?(new_props, name) do
        at(path, "property #{name} removed", :both)
      end

    nested =
      for name <- sorted_keys(old_props),
          Map.has_key?(new_props, name),
          {old_prop, new_prop} = {old_props[name], new_props[name]},
          change <- walk(join(path, name), old_prop, new_prop, property(ctx, old_prop, new_prop)),
          do: change

    added ++ removed ++ nested
  end

  defp property(ctx, old, new) do
    case ignored_side(old, new) do
      nil -> ctx
      side -> %{ctx | ignore: side}
    end
  end

  # A `readOnly` property is never sent, a `writeOnly` one never read.
  defp ignored_side(old, new) do
    cond do
      flag?(old, new, "readOnly") -> :request
      flag?(old, new, "writeOnly") -> :response
      true -> nil
    end
  end

  # `effect` for a change to a property, short of the side it's ignored on.
  defp only(effect, old_prop, new_prop), do: ignoring(effect, ignored_side(old_prop, new_prop))

  defp flag?(old, new, key),
    do: is_map(old) and is_map(new) and old[key] == true and new[key] == true

  # Only properties present in both versions — added and removed ones
  # are reported by `properties/4`.
  defp required(path, old, new) do
    {old_props, new_props} = {old["properties"] || %{}, new["properties"] || %{}}
    both = MapSet.intersection(MapSet.new(Map.keys(old_props)), MapSet.new(Map.keys(new_props)))
    old_required = MapSet.new(List.wrap(old["required"]))
    new_required = MapSet.new(List.wrap(new["required"]))

    for name <- Enum.sort(both),
        MapSet.member?(old_required, name) != MapSet.member?(new_required, name) do
      {old_prop, new_prop} = {old_props[name], new_props[name]}

      if MapSet.member?(new_required, name),
        do: at(path, "#{name} is now required", only(:request, old_prop, new_prop)),
        else: at(path, "#{name} is no longer required", only(:response, old_prop, new_prop))
    end
  end

  defp items(path, old, new, ctx) do
    case {old["items"], new["items"]} do
      {nil, nil} -> []
      {nil, _items} -> [at(path, "items (none) → schema", :request)]
      {_items, nil} -> [at(path, "items schema → (none)", :response)]
      {old_items, new_items} -> walk(path <> "[]", old_items, new_items, ctx)
    end
  end

  defp additional(path, old, new, ctx) do
    case {extra(old), extra(new)} do
      {same, same} ->
        []

      {%{} = old, %{} = new} ->
        walk(path <> "{}", old, new, ctx)

      {old, new} ->
        effect = if openness(new) < openness(old), do: :request, else: :response
        [at(path, "additionalProperties #{extra_name(old)} → #{extra_name(new)}", effect)]
    end
  end

  # `additionalProperties` absent, `true` and `{}` all allow anything.
  defp extra(value) when value in [nil, true, %{}], do: true
  defp extra(value), do: value

  defp openness(true), do: 2
  defp openness(false), do: 0
  defp openness(_schema), do: 1

  defp extra_name(value) when is_boolean(value), do: to_string(value)
  defp extra_name(_schema), do: "schema"

  defp composition(_path, _key, {same, same}, _ctx), do: []

  defp composition(path, key, {old, new}, ctx) do
    old = List.wrap(old)
    new = List.wrap(new)

    if length(old) == length(new) do
      old
      |> Enum.zip(new)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{o, n}, i} -> walk(join(path, "#{key}[#{i}]"), o, n, ctx) end)
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
