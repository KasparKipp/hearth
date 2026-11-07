defmodule Hearth.Spec.Drift.Usage do
  @moduledoc false

  # Where each component schema is used: sent in requests (parameters,
  # request bodies), read in responses, or both. Drift judges a schema's
  # changes by it — a tighter request or a looser response is breaking.
  #
  # Walks every operation's roots and follows local `$ref`s (through
  # `components/parameters`, `requestBodies`, `responses` and schemas),
  # each once, so cycles end. Pure.

  @type side :: :request | :response | :both
  @type sides :: %{String.t() => side()}

  @methods ~w(get put post delete options head patch trace)
  @schema_ref "#/components/schemas/"

  @spec sides(map()) :: sides()
  def sides(spec) do
    for {side, root} <- roots(spec), name <- schemas_reached(spec, root), reduce: %{} do
      acc -> Map.update(acc, name, side, &both(&1, side))
    end
  end

  @spec union(sides(), sides()) :: sides()
  def union(a, b), do: Map.merge(a, b, fn _name, x, y -> both(x, y) end)

  # Folds a `sources:` merge's copies into their plain names
  # (`Drift.Copies` pairs), so `items_Pet` and `Pet` share a side.
  @spec rename(sides(), %{String.t() => {atom(), String.t()}}) :: sides()
  def rename(sides, pairs) do
    Enum.reduce(sides, %{}, fn {name, side}, acc ->
      {_key, plain} = Map.get(pairs, name, {nil, name})
      Map.update(acc, plain, side, &both(&1, side))
    end)
  end

  # A schema no operation reaches could be either.
  @spec side(sides(), String.t()) :: side()
  def side(sides, name), do: Map.get(sides, name, :both)

  defp both(same, same), do: same
  defp both(_a, _b), do: :both

  defp roots(spec) do
    for {_path, item} <- spec["paths"] || %{}, is_map(item), root <- item_roots(item), do: root
  end

  defp item_roots(item) do
    operations = for method <- @methods, is_map(item[method]), do: item[method]

    [{:request, item["parameters"]}] ++
      Enum.flat_map(operations, fn op ->
        [
          {:request, op["parameters"]},
          {:request, op["requestBody"]},
          {:response, op["responses"]}
        ]
      end)
  end

  defp schemas_reached(spec, root), do: follow(spec, refs(root), MapSet.new())

  defp follow(_spec, [], seen) do
    for @schema_ref <> name <- seen, do: unescape(name)
  end

  defp follow(spec, [ref | rest], seen) do
    if MapSet.member?(seen, ref),
      do: follow(spec, rest, seen),
      else: follow(spec, refs(target(spec, ref)) ++ rest, MapSet.put(seen, ref))
  end

  defp refs(%{"$ref" => "#/" <> _ = ref} = map), do: [ref | refs(Map.delete(map, "$ref"))]
  defp refs(map) when is_map(map), do: Enum.flat_map(Map.values(map), &refs/1)
  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_value), do: []

  defp target(spec, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.reduce(spec, fn key, node -> if is_map(node), do: node[unescape(key)] end)
  end

  defp unescape(segment), do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")
end
