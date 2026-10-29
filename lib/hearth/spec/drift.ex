defmodule Hearth.Spec.Drift do
  @moduledoc false

  # Compares an integration's pruned spec with a fresh prune of its
  # source (same `tags:`), and lists what changed — what `mix
  # hearth.diff` reports. Each change is additive or breaking for a
  # caller of the generated client:
  #
  #   * operations, matched by method + path: added (additive), removed
  #     (breaking), moved to another path — matched by `operationId` —
  #     (breaking only when the path parameters change), `operationId`
  #     renamed (not breaking: regen renames the function, and the
  #     detail names the call sites to rename)
  #   * inside an operation: parameters (local `$ref`s resolved), the
  #     request body and responses, with schemas compared by
  #     `Hearth.Spec.Drift.Schema`
  #   * `components/schemas`, by name: added, removed, changed. A
  #     `sources:` merge's per-source copies (`items_Pet`) pair with the
  #     plain name on the other side (`Drift.Copies`): a split or join is
  #     one non-breaking line plus each source's own changes, and `$ref`s
  #     to a copy count as refs to the plain name — the generated code
  #     never names a schema
  #   * the auth scheme Layer 1 wires (breaking when it changes)
  #
  # Documentation (`summary`, `description`, `example`, …) is ignored.

  alias Hearth.Spec.Auth
  alias Hearth.Spec.Drift.Copies
  alias Hearth.Spec.Drift.Schema
  alias Hearth.Spec.Operation

  @methods ~w(get put post delete options head patch trace)

  @type change :: %{
          area: :auth | :operation | :schema,
          kind: :added | :removed | :changed,
          subject: String.t(),
          detail: String.t() | nil,
          breaking?: boolean()
        }

  # `merge` — `keys:` the `sources:` keys, `splits:` the components the
  # merge split (`Hearth.Spec.Merge`); empty for one source.
  @spec compare(map(), map(), keyword()) :: [change()]
  def compare(current, candidate, merge \\ []) do
    {splits, joins} = Copies.pairs(current, candidate, merge)
    current = Copies.plain_refs(current, joins)
    candidate = Copies.plain_refs(candidate, splits)

    auth(current, candidate) ++
      operations(current, candidate) ++
      schemas(current, candidate, splits, joins, Keyword.get(merge, :keys, []))
  end

  @spec breaking?([change()]) :: boolean()
  def breaking?(changes), do: Enum.any?(changes, & &1.breaking?)

  # One report line: `+ post /pets (createPets)`,
  # `~ Pet: property age added`, `- Child  [breaking]`.
  @spec format(change()) :: String.t()
  def format(change) do
    detail = if change.detail, do: ": #{change.detail}", else: ""
    breaking = if change.breaking?, do: "  [breaking]", else: ""
    "#{sign(change.kind)} #{change.subject}#{detail}#{breaking}"
  end

  defp sign(:added), do: "+"
  defp sign(:removed), do: "-"
  defp sign(:changed), do: "~"

  # --- auth ---------------------------------------------------------------

  # The scheme Layer 1 wires (`Hearth.Spec.Auth`). A change rewires the
  # client and its credential config — breaking for callers.
  defp auth(current, candidate) do
    case {Auth.strategy(current), Auth.strategy(candidate)} do
      {same, same} ->
        []

      {old, new} ->
        detail = "#{Auth.label(old)} → #{Auth.label(new)}"
        [%{area: :auth, kind: :changed, subject: "auth", detail: detail, breaking?: true}]
    end
  end

  # --- operations ---------------------------------------------------------

  defp operations(current, candidate) do
    old = list_operations(current)
    new = list_operations(candidate)
    new_keys = MapSet.new(new, & &1.key)
    old_keys = MapSet.new(old, & &1.key)

    gone = Enum.reject(old, &MapSet.member?(new_keys, &1.key))
    fresh = Enum.reject(new, &MapSet.member?(old_keys, &1.key))
    moves = moves(gone, fresh)
    moved_to = MapSet.new(Map.values(moves), & &1.key)

    old_changes =
      Enum.flat_map(old, fn op ->
        cond do
          MapSet.member?(new_keys, op.key) ->
            compare_operation(op, Enum.find(new, &(&1.key == op.key)), current, candidate)

          moved = moves[op.key] ->
            [
              change(
                :operation,
                :changed,
                op,
                "moved to #{moved.method} #{moved.path}",
                moved?(op, moved)
              )
            ]

          true ->
            [change(:operation, :removed, op, nil, true)]
        end
      end)

    added =
      for op <- fresh, not MapSet.member?(moved_to, op.key) do
        change(:operation, :added, op, nil, false)
      end

    old_changes ++ added
  end

  defp list_operations(spec) do
    paths = spec["paths"] || %{}
    functions = function_names(spec)

    for path <- paths |> Map.keys() |> Enum.sort(),
        method <- @methods,
        op = paths[path][method],
        is_map(op) do
      %{
        key: {method, path},
        method: method,
        path: path,
        id: op["operationId"],
        function: functions[{method, path}],
        op: op,
        params: List.wrap(paths[path]["parameters"])
      }
    end
  end

  # A removed operation whose `operationId` turns up at a new method +
  # path moved there.
  defp moves(gone, fresh) do
    for op <- gone, op.id, target = Enum.find(fresh, &(&1.id == op.id)), into: %{} do
      {op.key, target}
    end
  end

  defp moved?(old, new), do: path_param_count(old.path) != path_param_count(new.path)

  defp path_param_count(path), do: length(Regex.scan(~r/\{[^}]+\}/, path))

  defp compare_operation(old, new, current, candidate) do
    details =
      operation_id(old, new) ++
        parameters(old, new, current, candidate) ++
        request_body(old.op["requestBody"], new.op["requestBody"], current, candidate) ++
        responses(old.op["responses"] || %{}, new.op["responses"] || %{}, current, candidate)

    for {detail, breaking?} <- details, do: change(:operation, :changed, old, detail, breaking?)
  end

  # The generated function name per method + path — what callers use,
  # including derived names and collision suffixes.
  defp function_names(spec) do
    spec
    |> Operation.extract()
    |> Map.new(&{{Atom.to_string(&1.method), &1.path}, &1.id})
  end

  # Only the operationId changed: regen renames the function and the
  # call sites follow — mechanical, so drift but not breaking.
  defp operation_id(%{id: same}, %{id: same}), do: []

  defp operation_id(%{function: same} = old, %{function: same} = new),
    do: [{"operationId #{old.id} → #{new.id} (function name unchanged)", false}]

  defp operation_id(old, new),
    do: [{"renamed to #{new.id} — call sites: #{old.function} → #{new.function}", false}]

  defp parameters(old, new, current, candidate) do
    old_params = resolved_params(old, current)
    new_params = resolved_params(new, candidate)

    added =
      for {key, param} <- new_params, not List.keymember?(old_params, key, 0) do
        if param["required"],
          do: {"#{param_label(key)} added, required", true},
          else: {"#{param_label(key)} added", false}
      end

    removed =
      for {key, _param} <- old_params, not List.keymember?(new_params, key, 0) do
        {"#{param_label(key)} removed", true}
      end

    common =
      for {key, old_param} <- old_params,
          {_key, new_param} <- [List.keyfind(new_params, key, 0)],
          change <- param_changes(key, old_param, new_param),
          do: change

    added ++ removed ++ common
  end

  # Path-item parameters, overridden by operation ones with the same
  # name + location, as `[{{in, name}, param}]`.
  defp resolved_params(op, spec) do
    (op.params ++ List.wrap(op.op["parameters"]))
    |> Enum.map(&resolve(spec, &1))
    |> Enum.filter(&(is_map(&1) and is_binary(&1["name"])))
    |> Enum.reduce([], fn param, acc ->
      List.keystore(acc, {param["in"], param["name"]}, 0, {{param["in"], param["name"]}, param})
    end)
  end

  defp param_label({location, name}), do: "#{location} parameter #{name}"

  defp param_changes(key, old, new) do
    required =
      case {old["required"] == true, new["required"] == true} do
        {same, same} -> []
        {false, true} -> [{"#{param_label(key)} is now required", true}]
        {true, false} -> [{"#{param_label(key)} is no longer required", false}]
      end

    required ++ prefixed(param_label(key), Schema.changes(old["schema"], new["schema"]))
  end

  defp request_body(nil, nil, _current, _candidate), do: []

  defp request_body(nil, new, _current, candidate) do
    if resolve(candidate, new)["required"],
      do: [{"request body added, required", true}],
      else: [{"request body added", false}]
  end

  defp request_body(_old, nil, _current, _candidate), do: [{"request body removed", true}]

  defp request_body(old, new, current, candidate) do
    old = resolve(current, old)
    new = resolve(candidate, new)

    required =
      case {old["required"] == true, new["required"] == true} do
        {same, same} -> []
        {false, true} -> [{"request body is now required", true}]
        {true, false} -> [{"request body is no longer required", false}]
      end

    required ++ content("request body", old["content"], new["content"])
  end

  defp responses(old, new, current, candidate) do
    codes = old |> Map.keys() |> Enum.concat(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(codes, fn code ->
      case {old[code], new[code]} do
        {nil, _new} ->
          [{"response #{code} added", false}]

        {_old, nil} ->
          [{"response #{code} removed", true}]

        {old_response, new_response} ->
          content(
            "response #{code}",
            resolve(current, old_response)["content"],
            resolve(candidate, new_response)["content"]
          )
      end
    end)
  end

  defp content(label, old, new) do
    old = old || %{}
    new = new || %{}
    types = old |> Map.keys() |> Enum.concat(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(types, fn type ->
      case {old[type], new[type]} do
        {nil, _new} -> [{"#{label} #{type} added", false}]
        {_old, nil} -> [{"#{label} #{type} removed", true}]
        {o, n} -> prefixed("#{label} #{type}", Schema.changes(o["schema"], n["schema"]))
      end
    end)
  end

  defp prefixed(label, changes) do
    for {detail, breaking?} <- changes, do: {"#{label}: #{detail}", breaking?}
  end

  # Follows a local `#/components/…` `$ref`, a few levels deep.
  defp resolve(spec, node, depth \\ 0)

  defp resolve(spec, %{"$ref" => "#/" <> pointer}, depth) when depth < 5 do
    case get_in(spec, String.split(pointer, "/")) do
      nil -> %{}
      target -> resolve(spec, target, depth + 1)
    end
  end

  defp resolve(_spec, node, _depth), do: node

  # --- components ---------------------------------------------------------

  defp schemas(current, candidate, splits, joins, keys) do
    old = Copies.schemas(current)
    new = Copies.schemas(candidate)
    copies = Map.merge(splits, joins)
    paired = copies |> Map.values() |> MapSet.new(&elem(&1, 1))

    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Kernel.--(Map.keys(copies))
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      if MapSet.member?(paired, name),
        do:
          paired_changes(name, old, new, {copies_of(splits, name), copies_of(joins, name)}, keys),
        else: schema_changes(name, old[name], new[name])
    end)
  end

  defp copies_of(pairs, name), do: for({copy, {key, ^name}} <- pairs, do: {key, copy})

  # A plain name and its copies: one non-breaking line for the split or
  # join, then each source compared with what it had — its copy, else
  # the plain name. Sources with no copy on either side read the plain
  # name on both.
  defp paired_changes(name, old, new, {split, joined} = copies, keys) do
    copied = Enum.filter(keys, &(Keyword.has_key?(split, &1) or Keyword.has_key?(joined, &1)))

    shared =
      if keys -- copied != [] and Map.has_key?(old, name) and Map.has_key?(new, name),
        do: schema_changes(name, old[name], new[name]),
        else: []

    [schema_change(:changed, name, pairing(name, old, new, copies), false)] ++
      shared ++ Enum.flat_map(copied, &copy_changes(&1, name, old, new, copies))
  end

  defp pairing(name, old, new, {split, joined}) do
    listed = fn copies -> copies |> Keyword.values() |> Enum.sort() |> Enum.join(", ") end

    cond do
      not Map.has_key?(new, name) ->
        "split per source into #{listed.(split)}"

      not Map.has_key?(old, name) ->
        "joined from #{listed.(joined)}"

      true ->
        [
          split != [] && "#{listed.(split)} split off from it",
          joined != [] && "#{listed.(joined)} joined it"
        ]
        |> Enum.filter(& &1)
        |> Enum.join("; ")
    end
  end

  defp copy_changes(key, name, old, new, {split, joined}) do
    old_copy = joined[key]
    new_copy = split[key]
    prefix = if old_copy && !new_copy, do: "from #{old_copy}: ", else: ""

    for {detail, breaking?} <- Schema.changes(old[old_copy || name], new[new_copy || name]),
        do: schema_change(:changed, new_copy || name, prefix <> detail, breaking?)
  end

  defp schema_changes(name, nil, _new), do: [schema_change(:added, name, nil, false)]
  defp schema_changes(name, _old, nil), do: [schema_change(:removed, name, nil, true)]

  defp schema_changes(name, old, new) do
    for {detail, breaking?} <- Schema.changes(old, new),
        do: schema_change(:changed, name, detail, breaking?)
  end

  defp schema_change(kind, name, detail, breaking?) do
    %{area: :schema, kind: kind, subject: name, detail: detail, breaking?: breaking?}
  end

  defp change(area, kind, op, detail, breaking?) do
    %{area: area, kind: kind, subject: label(op), detail: detail, breaking?: breaking?}
  end

  defp label(%{method: method, path: path, id: nil}), do: "#{method} #{path}"
  defp label(%{method: method, path: path, id: id}), do: "#{method} #{path} (#{id})"
end
