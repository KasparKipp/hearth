defmodule Hearth.Spec.Merge do
  @moduledoc false

  # Merges the specs of an integration's `sources:` — modules of one API
  # behind one host — into one OpenAPI document, so everything
  # downstream works as for one source.
  #
  #   * each source's server path moves into its paths (`/items/v1` +
  #     `/items/{id}` → `/items/v1/items/{id}`); the merged spec keeps
  #     the one host they share, or no servers when none has a host.
  #     Different hosts halt — one client has one base URL;
  #   * paths are unioned; a path or operationId two sources share halts;
  #   * components the sources define alike — docs (`description`,
  #     `summary`, `title`, examples, `externalDocs`) aside — are kept
  #     once, as the first source has them (`alike?/2`). A name two
  #     sources shape differently gets the source key as a prefix in each
  #     (`items_address`, `orders_address`), with that source's refs
  #     rewritten — repeated until stable, since a component that only
  #     differs through a renamed ref then differs too. `keep` pins a
  #     plain name to one source (`%{{"schemas", "address"} => :items}`,
  #     from `overrides: [shared: …]`): that source keeps it, only the
  #     others are prefixed; when the copies are alike, its copy is kept. The split components without a keeper are
  #     returned, so diff can warn when a shared name splits;
  #   * tags and security are unioned, info names every source (and
  #     keeps a description only when they share it), and the first
  #     source wins any other top-level key.
  #
  # Pure. Sources are OpenAPI 3 (Swagger is converted before).

  @type component :: {String.t(), String.t()}

  @docs ~w(description summary title example examples externalDocs)
  # Keys whose maps are keyed by names (property, header, media type,
  # discriminator value …), where a name like `title` is shape, not docs.
  @named ~w(properties patternProperties $defs definitions dependentSchemas dependentRequired
            dependencies headers content encoding links callbacks responses parameters
            variables mapping)
  # Keys whose values are data, compared as they are.
  @data ~w(default enum const value)

  @spec merge([{atom(), map()}], %{component() => atom()}) ::
          {:ok, map(), [component()]} | {:error, String.t()}
  def merge([_ | _] = sources, keep \\ %{}) do
    with {:ok, origin} <- origin(sources) do
      {sources, splits} =
        sources
        |> Enum.map(fn {key, spec} -> {key, fold_server_path(spec)} end)
        |> disambiguate(keep, [])

      with {:ok, paths} <- paths(sources),
           :ok <- unique_operation_ids(sources) do
        {:ok, document(sources, paths, origin, keep), splits -- Map.keys(keep)}
      end
    end
  end

  defp origin(sources) do
    origins =
      sources
      |> Enum.map(fn {_key, spec} -> spec |> server_uri() |> origin_of() end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case origins do
      [] -> {:ok, nil}
      [origin] -> {:ok, origin}
      many -> {:error, hosts_message(many)}
    end
  end

  defp server_uri(spec) do
    case spec["servers"] do
      [%{"url" => url} | _] when is_binary(url) -> URI.parse(url)
      _ -> nil
    end
  end

  defp origin_of(%URI{scheme: scheme, host: host} = uri)
       when is_binary(scheme) and is_binary(host),
       do: URI.to_string(%URI{scheme: scheme, host: host, port: uri.port})

  defp origin_of(_uri), do: nil

  defp fold_server_path(spec) do
    prefix =
      case server_uri(spec) do
        %URI{path: path} when is_binary(path) -> String.trim_trailing(path, "/")
        _ -> ""
      end

    paths = Map.new(spec["paths"] || %{}, fn {path, item} -> {prefix <> path, item} end)
    spec |> Map.put("paths", paths) |> Map.delete("servers")
  end

  defp disambiguate(sources, keep, splits) do
    case conflicts(sources) do
      [] ->
        {sources, Enum.uniq(splits)}

      conflicts ->
        sources
        |> Enum.map(fn {key, spec} ->
          {key, rename(spec, key, Enum.reject(conflicts, &(keep[&1] == key)))}
        end)
        |> disambiguate(keep, splits ++ conflicts)
    end
  end

  # `{section, name}` pairs that two sources shape differently.
  defp conflicts(sources) do
    sources
    |> Enum.flat_map(fn {_key, spec} ->
      for {section, entries} <- spec["components"] || %{},
          is_map(entries),
          {name, value} <- entries,
          do: {{section, name}, shape(value)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_component, values} -> values |> Enum.uniq() |> length() > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  # Whether two copies of a component differ only in docs.
  @spec alike?(term(), term()) :: boolean()
  def alike?(a, b), do: shape(a) == shape(b)

  defp shape(%{} = map) do
    for {key, value} <- map, key not in @docs, into: %{} do
      cond do
        key in @data or String.starts_with?(key, "x-") -> {key, value}
        key in @named and is_map(value) -> {key, Map.new(value, fn {k, v} -> {k, shape(v)} end)}
        true -> {key, shape(value)}
      end
    end
  end

  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(value), do: value

  defp rename(spec, key, conflicts) do
    renames =
      for {section, name} <- conflicts,
          Map.has_key?(spec["components"][section] || %{}, name),
          into: %{},
          do: {"#/components/#{section}/#{name}", {section, name, "#{key}_#{name}"}}

    components =
      Enum.reduce(renames, spec["components"], fn {_ref, {section, name, new}}, acc ->
        {value, entries} = Map.pop(acc[section], name)
        Map.put(acc, section, Map.put(entries, new, value))
      end)

    spec
    |> Map.put("components", components)
    |> rewrite_refs(
      Map.new(renames, fn {ref, {section, _name, new}} ->
        {ref, "#/components/#{section}/#{new}"}
      end)
    )
  end

  defp rewrite_refs(%{"$ref" => ref} = map, renames) when is_map_key(renames, ref),
    do: Map.put(map, "$ref", Map.fetch!(renames, ref))

  defp rewrite_refs(map, renames) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, rewrite_refs(v, renames)} end)

  defp rewrite_refs(list, renames) when is_list(list),
    do: Enum.map(list, &rewrite_refs(&1, renames))

  defp rewrite_refs(value, _renames), do: value

  defp paths(sources) do
    owners = for {key, spec} <- sources, path <- Map.keys(spec["paths"]), do: {path, key}

    case owners
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
         |> Enum.find(&match?({_, [_, _ | _]}, &1)) do
      nil ->
        {:ok,
         Enum.reduce(sources, %{}, fn {_key, spec}, acc -> Map.merge(acc, spec["paths"]) end)}

      {path, [first, second | _]} ->
        {:error, path_message(path, first, second)}
    end
  end

  defp unique_operation_ids(sources) do
    ids =
      for {key, spec} <- sources,
          {_path, item} <- spec["paths"],
          is_map(item),
          {_method, op} <- item,
          is_map(op) and is_binary(op["operationId"]),
          do: {op["operationId"], key}

    case ids
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
         |> Enum.find(&match?({_, [_, _ | _]}, &1)) do
      nil -> :ok
      {id, keys} -> {:error, operation_id_message(id, keys)}
    end
  end

  defp document(sources, paths, origin, keep) do
    specs = Enum.map(sources, &elem(&1, 1))
    [first | _] = specs

    components =
      specs
      |> Enum.reduce(%{}, fn spec, acc ->
        Map.merge(acc, spec["components"] || %{}, fn _section, a, b -> Map.merge(b, a) end)
      end)
      |> keep_pinned(sources, keep)

    first
    |> Map.put("paths", paths)
    |> Map.put("info", info(specs))
    |> put_present("servers", if(origin, do: [%{"url" => origin}]))
    |> put_present(
      "tags",
      specs |> Enum.flat_map(&List.wrap(&1["tags"])) |> Enum.uniq_by(& &1["name"])
    )
    |> put_present("security", specs |> Enum.flat_map(&List.wrap(&1["security"])) |> Enum.uniq())
    |> put_present("components", components)
  end

  # A pinned source's copy wins over the first source's alike one.
  defp keep_pinned(components, sources, keep) do
    Enum.reduce(keep, components, fn {{section, name}, key}, acc ->
      case get_in(sources, [key, "components", section, name]) do
        nil -> acc
        value -> put_in(acc, [section, name], value)
      end
    end)
  end

  defp info([first | _] = specs) do
    joined = fn key, sep ->
      specs
      |> Enum.map(&get_in(&1, ["info", key]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(sep)
    end

    descriptions = specs |> Enum.map(&get_in(&1, ["info", "description"])) |> Enum.uniq()

    (first["info"] || %{})
    |> Map.merge(%{"title" => joined.("title", " + "), "version" => joined.("version", ", ")})
    |> then(&if(length(descriptions) > 1, do: Map.delete(&1, "description"), else: &1))
  end

  defp put_present(map, key, value) when value in [nil, [], %{}], do: Map.delete(map, key)
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp hosts_message(origins) do
    "`sources:` point at different hosts (#{Enum.join(origins, ", ")}), and one client has " <>
      "one base URL. Use one integration per host."
  end

  defp path_message(path, first, second),
    do: "`sources:` #{first} and #{second} both define #{inspect(path)}."

  defp operation_id_message(id, keys) do
    "`sources:` #{Enum.join(keys, " and ")} both use the operationId #{inspect(id)}; " <>
      "functions are named after it, so it must be unique."
  end
end
