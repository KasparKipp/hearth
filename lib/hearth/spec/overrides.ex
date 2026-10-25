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
  #       ]
  #     ]
  #
  #   * `tags` — adds a tag to the operations an entry matches: a path
  #     glob (`/…`, `*` matches anything, `/` included), a method plus a
  #     glob (`get /…`), or an operationId. Upstream tags stay.
  #
  # Overrides refer to the source's own paths and operationIds. One
  # that matches nothing is returned as stale, for the tasks to report.

  @kinds [:tags]
  @methods ~w(get put post delete options head patch trace)

  @type t :: %{tags: [{String.t(), [String.t()]}]}
  @type stale :: {:tags, String.t(), String.t()}

  @spec parse(keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(entry) do
    overrides = Keyword.get(entry, :overrides, [])

    with true <- Keyword.keyword?(overrides) || {:error, shape_message()},
         :ok <- known_kinds(overrides),
         {:ok, tags} <- tags(Keyword.get(overrides, :tags, [])) do
      {:ok, %{tags: tags}}
    end
  end

  defp known_kinds(overrides) do
    case Keyword.keys(overrides) -- @kinds do
      [] -> :ok
      unknown -> {:error, unknown_message(unknown)}
    end
  end

  # Returns the overridden spec and the override entries that matched
  # no operation.
  @spec apply(map(), t()) :: {map(), [stale()]}
  def apply(spec, %{tags: []}), do: {spec, []}

  def apply(spec, %{tags: tags}) do
    operations = operations(spec)

    stale =
      for {tag, entries} <- tags,
          entry <- entries,
          not Enum.any?(operations, &matches?(entry, &1)),
          do: {:tags, tag, entry}

    spec =
      Enum.reduce(operations, spec, fn {path, method, op} = operation, acc ->
        added = for {tag, entries} <- tags, Enum.any?(entries, &matches?(&1, operation)), do: tag

        upstream = List.wrap(op["tags"])
        tagged = Enum.uniq(upstream ++ added)

        if tagged == upstream, do: acc, else: put_in(acc, ["paths", path, method, "tags"], tagged)
      end)

    {spec, stale}
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

  defp shape_message do
    "`overrides:` must be a keyword list, e.g. `overrides: [tags: [Customers: [\"/v1/customers*\"]]]`."
  end

  defp unknown_message(unknown) do
    "unknown override #{Enum.map_join(unknown, ", ", &"`#{&1}:`")} — " <>
      "supported: #{Enum.map_join(@kinds, ", ", &"`#{&1}:`")}."
  end
end
