defmodule Hearth.Spec.Prune do
  @moduledoc false

  # Prunes a decoded OpenAPI spec down to the subset of operations an
  # integration actually uses.
  #
  #   * `info` / `servers` / `security` / `tags` / extensions — kept
  #     untouched;
  #   * `paths` — filtered to the selected operations (path-item-level
  #     keys like `parameters` ride along, applying to every method);
  #   * `components` — filtered to only the entries transitively
  #     reachable by `$ref` from the kept paths. `securitySchemes` is
  #     kept whole (tiny, and the auth strategy needs it).
  #
  # This is reachability *tracking* — nothing is resolved/inlined.
  #
  # Pure: works on the raw decoded map. The gen task encodes the result
  # to YAML and writes it as the integration's versioned spec.

  alias Hearth.Spec.Operation

  @http_methods ~w(get post put delete patch head options trace)

  # Conventional OpenAPI top-level key order. A decoded spec is a plain
  # map (order already lost), and `ymlr` emits map keys in term order
  # (≈ alphabetical) — so `to_yaml/1` re-imposes this order.
  @top_level_order ~w(openapi info jsonSchemaDialect servers security
                      tags externalDocs paths webhooks components)

  @spec prune(map(), [Operation.t()]) :: map()
  def prune(spec, selected) when is_map(spec) do
    paths = prune_paths(Map.get(spec, "paths", %{}), selected)
    components = prune_components(Map.get(spec, "components", %{}), paths)

    spec
    |> Map.put("paths", paths)
    |> put_components(components)
  end

  defp put_components(spec, components) when components == %{},
    do: Map.delete(spec, "components")

  defp put_components(spec, components), do: Map.put(spec, "components", components)

  @doc """
  Encodes a spec map to a YAML document with conventional top-level
  key order (`openapi`, `info`, `servers`, … `paths`, `components`).

  Each top-level key is encoded on its own so `ymlr` (which iterates a
  map in term order) cannot re-alphabetize them. Nested keys stay
  sorted — deterministic, and only the top level was asked for.
  """
  @spec to_yaml(map()) :: String.t()
  def to_yaml(spec) when is_map(spec) do
    ordered = @top_level_order ++ (Map.keys(spec) -- @top_level_order)

    body =
      ordered
      |> Enum.filter(&Map.has_key?(spec, &1))
      |> Enum.map_join("\n", fn key -> Ymlr.Encode.to_s!(%{key => spec[key]}) end)

    "---\n" <> body <> "\n"
  end

  defp prune_paths(paths, selected) do
    selected
    |> Enum.group_by(& &1.path, &to_string(&1.method))
    |> Map.new(fn {path, methods} ->
      kept =
        paths
        |> Map.get(path, %{})
        |> Map.filter(fn {key, _value} -> key in methods or key not in @http_methods end)

      {path, kept}
    end)
  end

  defp prune_components(components, _paths) when components == %{}, do: %{}

  defp prune_components(components, paths) do
    reachable = ref_closure(collect_refs(paths), components, %{})

    components
    |> Map.new(fn
      {"securitySchemes", entries} ->
        {"securitySchemes", entries}

      {section, entries} ->
        names = reachable |> Map.get(section, MapSet.new()) |> MapSet.to_list()
        {section, Map.take(entries, names)}
    end)
    |> Map.reject(fn {_section, entries} -> entries == %{} end)
  end

  # BFS over `#/components/<section>/<name>` refs, following each kept
  # component's own refs. `acc` is `%{section => MapSet of names}`.
  defp ref_closure([], _components, acc), do: acc

  defp ref_closure([ref | rest], components, acc) do
    case parse_ref(ref) do
      {section, name} ->
        seen = Map.get(acc, section, MapSet.new())

        if MapSet.member?(seen, name) do
          ref_closure(rest, components, acc)
        else
          acc = Map.put(acc, section, MapSet.put(seen, name))
          entry = get_in(components, [section, name])
          ref_closure(collect_refs(entry) ++ rest, components, acc)
        end

      :error ->
        ref_closure(rest, components, acc)
    end
  end

  defp parse_ref("#/components/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [section, name] -> {section, name}
      _ -> :error
    end
  end

  defp parse_ref(_ref), do: :error

  # Every `$ref` string anywhere inside a node — through nested maps,
  # lists (`allOf`/`anyOf`/`oneOf`, `items`), and `$ref`-with-siblings.
  defp collect_refs(%{} = map) do
    Enum.flat_map(map, fn
      {"$ref", ref} when is_binary(ref) -> [ref]
      {_key, value} -> collect_refs(value)
    end)
  end

  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_scalar), do: []
end
