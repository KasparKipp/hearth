defmodule Hearth.Spec.Overrides do
  @moduledoc false

  # An integration's `overrides:` block in `.hearth.exs` — corrections
  # to the source spec as published, applied to the decoded source
  # before anything else looks at it (selection, pruning, rendering,
  # drift). The pruned spec carries the result, so `regen` needs no
  # overrides of its own.
  #
  #     overrides: [
  #       tags: [
  #         Customers: ["/v1/customers*", "PostCustomerSearch"],
  #         Billing: ["get /v1/invoices*"]
  #       ],
  #       operation_ids: %{"GetCustomersCustomer" => "GetCustomer"}
  #     ]
  #
  #   * `tags` — adds a tag to the operations an entry matches: a path
  #     glob (`/…`, `*` matches anything, `/` included), a method plus a
  #     glob (`get /…`), or an operationId. Upstream tags stay.
  #   * `operation_ids` — gives an operation a new operationId, found by
  #     its upstream id or, without one, by `"method /path"`. The
  #     generated function follows (`GetCustomer` → `get_customer`). A
  #     new id that another operation already has, or that generates the
  #     same function, is an error.
  #
  # Overrides refer to the source as published — its paths and upstream
  # operationIds — so tags apply before renames and never depend on
  # them. Everything downstream sees the result. An entry that matches
  # nothing is returned as stale, for the tasks to report.

  @kinds [:tags, :operation_ids]
  @methods ~w(get put post delete options head patch trace)

  alias Hearth.Spec.Operation

  @type t :: %{tags: [{String.t(), [String.t()]}], operation_ids: %{String.t() => String.t()}}
  @type stale :: {:tags | :operation_ids, String.t()}

  @spec parse(keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(entry) do
    overrides = Keyword.get(entry, :overrides, [])

    with true <- Keyword.keyword?(overrides) || {:error, shape_message()},
         :ok <- known_kinds(overrides),
         {:ok, tags} <- tags(Keyword.get(overrides, :tags, [])),
         {:ok, ids} <- operation_ids(Keyword.get(overrides, :operation_ids, %{})) do
      {:ok, %{tags: tags, operation_ids: ids}}
    end
  end

  defp known_kinds(overrides) do
    case Keyword.keys(overrides) -- @kinds do
      [] -> :ok
      unknown -> {:error, unknown_message(unknown)}
    end
  end

  # Returns the overridden spec and the override entries that matched
  # nothing, or an error when a rename collides.
  @spec apply(map(), t()) :: {:ok, map(), [stale()]} | {:error, String.t()}
  def apply(spec, overrides) do
    {spec, tag_stale} = apply_tags(spec, overrides.tags)

    with {:ok, spec, id_stale} <- apply_operation_ids(spec, overrides.operation_ids) do
      {:ok, spec, tag_stale ++ id_stale}
    end
  end

  defp apply_tags(spec, []), do: {spec, []}

  defp apply_tags(spec, tags) do
    operations = operations(spec)

    stale =
      for {tag, entries} <- tags,
          entry <- entries,
          not Enum.any?(operations, &matches?(entry, &1)),
          do: {:tags, "#{tag}: #{inspect(entry)}"}

    spec =
      Enum.reduce(operations, spec, fn {path, method, op} = operation, acc ->
        added = for {tag, entries} <- tags, Enum.any?(entries, &matches?(&1, operation)), do: tag

        upstream = List.wrap(op["tags"])
        tagged = Enum.uniq(upstream ++ added)

        if tagged == upstream, do: acc, else: put_in(acc, ["paths", path, method, "tags"], tagged)
      end)

    {spec, stale}
  end

  defp apply_operation_ids(spec, ids) when map_size(ids) == 0, do: {:ok, spec, []}

  defp apply_operation_ids(spec, ids) do
    operations = operations(spec)

    stale =
      for key <- ids |> Map.keys() |> Enum.sort(),
          not Enum.any?(operations, &key?(key, &1)),
          do: {:operation_ids, inspect(key)}

    renamed =
      for {path, method, op} = operation <- operations,
          {key, new_id} <- ids,
          key?(key, operation),
          do: {path, method, op["operationId"], new_id}

    spec =
      Enum.reduce(renamed, spec, fn {path, method, _old, new_id}, acc ->
        put_in(acc, ["paths", path, method, "operationId"], new_id)
      end)

    case collision(spec, renamed) do
      nil -> {:ok, spec, stale}
      message -> {:error, message}
    end
  end

  defp key?(key, {path, method, op}), do: op["operationId"] == key or key == "#{method} #{path}"

  # A renamed operation whose new id — or the function it generates —
  # another operation already has.
  defp collision(spec, renamed) do
    operations = Operation.extract(spec)

    Enum.find_value(renamed, fn {path, method, old, new_id} ->
      function = Operation.function_name(new_id)

      clash =
        Enum.find(operations, fn other ->
          {Atom.to_string(other.method), other.path} != {method, path} and
            (other.operation_id == new_id or base_function(other) == function)
        end)

      if clash, do: collision_message(path, method, old, new_id, clash, function)
    end)
  end

  defp base_function(%Operation{operation_id: id}) when is_binary(id),
    do: Operation.function_name(id)

  defp base_function(%Operation{id: id}), do: id

  defp collision_message(path, method, old, new_id, clash, function) do
    from = if old, do: "#{method} #{path} (#{old})", else: "#{method} #{path}"
    other = if clash.operation_id, do: " (#{clash.operation_id})", else: ""

    "`operation_ids:` renames #{from} to #{inspect(new_id)}, which clashes with " <>
      "#{clash.method} #{clash.path}#{other} — both would generate `#{function}`. " <>
      "Pick another id."
  end

  defp operations(spec) do
    for {path, item} <- spec["paths"] || %{},
        is_map(item),
        {method, op} <- item,
        method in @methods,
        is_map(op),
        do: {path, method, op}
  end

  defp matches?("/" <> _ = glob, {path, _method, _op}), do: glob?(glob, path)

  defp matches?(entry, {path, method, op}) do
    case String.split(entry, " ", parts: 2) do
      [verb, "/" <> _ = glob] -> String.downcase(verb) == method and glob?(glob, path)
      _ -> op["operationId"] == entry
    end
  end

  defp glob?(glob, path) do
    pattern = glob |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.match?(~r/\A#{pattern}\z/, path)
  end

  defp tags(tags) do
    if Keyword.keyword?(tags) and
         Enum.all?(tags, fn {_tag, entries} ->
           is_list(entries) and Enum.all?(entries, &is_binary/1)
         end) do
      {:ok, Enum.map(tags, fn {tag, entries} -> {Atom.to_string(tag), entries} end)}
    else
      {:error,
       "`overrides: [tags: …]` must map tag names to lists of path globs, " <>
         ~s|"method /path" globs or operationIds, e.g. `tags: [Customers: ["/v1/customers*"]]`.|}
    end
  end

  defp operation_ids(ids) do
    if is_map(ids) and Enum.all?(ids, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, ids}
    else
      {:error,
       "`overrides: [operation_ids: …]` must map upstream operationIds (or " <>
         ~s|"method /path") to new ones, e.g. `operation_ids: %{"GetCustomersCustomer" => "GetCustomer"}`.|}
    end
  end

  defp shape_message do
    "`overrides:` must be a keyword list, e.g. `overrides: [tags: [Customers: [\"/v1/customers*\"]]]`."
  end

  defp unknown_message(unknown) do
    "unknown override #{Enum.map_join(unknown, ", ", &"`#{&1}:`")} — " <>
      "supported: #{Enum.map_join(@kinds, ", ", &"`#{&1}:`")}."
  end
end
