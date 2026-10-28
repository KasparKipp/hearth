defmodule Hearth.Spec.Selection do
  @moduledoc false

  # Describes which of a spec's operations an integration selected, tag
  # by tag — the declarative record `mix hearth.gen` writes into the
  # integration's `.hearth.exs` entry:
  #
  #     tags: [
  #       pets: [include: ["listPets"], exclude: ["createPets", "showPetById"]],
  #       store: :none,
  #       users: :all
  #     ],
  #     untagged: :all
  #
  # Every tag in the spec is listed, in first-seen operation order: `:all`
  # when each of its operations is selected, `:none` when none is, and
  # include / exclude lists otherwise. An operation tagged twice counts
  # under both tags. Operations with no tag go under `:untagged`, which
  # is omitted when there are none. Operations are named by their spec
  # `operationId`, or by the derived function name without one.
  #
  # Tag keys are atoms of the exact tag name (`:"Customer Accounts"` for
  # a tag with a space), so they read as a keyword list in `.hearth.exs`.

  alias Hearth.Spec.Operation

  @type state :: :all | :none | [include: [String.t()], exclude: [String.t()]]

  @spec describe([Operation.t()], [Operation.t()]) :: keyword()
  def describe(operations, selected) do
    selected_keys = MapSet.new(selected, &key/1)

    tags =
      operations
      |> Enum.flat_map(& &1.tags)
      |> Enum.uniq()
      |> Enum.map(fn tag ->
        {String.to_atom(tag), state(Enum.filter(operations, &(tag in &1.tags)), selected_keys)}
      end)

    case Enum.filter(operations, &(&1.tags == [])) do
      [] -> [tags: tags]
      untagged -> [tags: tags, untagged: state(untagged, selected_keys)]
    end
  end

  # The selection rule an entry's `tags:` / `untagged:` declare, for
  # re-applying to a spec: `regen --sync` selects from the source with
  # it, plain `regen` checks the pruned spec against it. `:none` when the
  # entry records no `tags:`.
  @type rule :: %{tags: %{String.t() => state()}, untagged: state() | nil}

  # `Hearth.Config.Schema` has checked the shape.
  @spec rule(keyword()) :: {:ok, rule()} | :none
  def rule(entry) do
    case Keyword.fetch(entry, :tags) do
      {:ok, tags} ->
        {:ok,
         %{
           tags: Map.new(tags, fn {tag, state} -> {Atom.to_string(tag), state} end),
           untagged: Keyword.get(entry, :untagged)
         }}

      :error ->
        :none
    end
  end

  # The operations `rule` selects, in their original order. An operation
  # is selected when any of its tags selects it — or, untagged, when
  # `untagged:` does. A tag the rule doesn't mention selects nothing.
  @spec select([Operation.t()], rule()) :: [Operation.t()]
  def select(operations, rule), do: Enum.filter(operations, &selected?(&1, rule))

  # Rewrites `rule`'s `include:` / `exclude:` lists for operations the
  # source renamed: an operation at the same method + path in `current`
  # (the pruned spec's) and `source` under a different name. Without it
  # an upstream operationId rename drops a partly selected operation.
  @spec carry_renames(rule(), [Operation.t()], [Operation.t()]) :: rule()
  def carry_renames(rule, current, source) do
    source_names = Map.new(source, &{key(&1), name(&1)})

    renames =
      for op <- current,
          new_name = source_names[key(op)],
          new_name && new_name != name(op),
          into: %{},
          do: {name(op), new_name}

    if renames == %{} do
      rule
    else
      %{
        rule
        | tags: Map.new(rule.tags, fn {tag, state} -> {tag, rename(state, renames)} end),
          untagged: rename(rule.untagged, renames)
      }
    end
  end

  defp rename(state, renames) when is_list(state) do
    Enum.map(state, fn {list, ids} -> {list, Enum.map(ids, &Map.get(renames, &1, &1))} end)
  end

  defp rename(state, _renames), do: state

  # Operations in a spec that `rule` doesn't select and doesn't mention:
  # under a tag it doesn't know, unlisted under a partly selected tag,
  # or untagged with no `untagged:` decision. New upstream operations,
  # for `mix hearth.diff` to report. A `:none` tag or an `exclude:` entry
  # is a decision already made, so those stay quiet.
  @spec unlisted([Operation.t()], rule()) :: [Operation.t()]
  def unlisted(operations, rule) do
    Enum.filter(operations, fn op ->
      not selected?(op, rule) and Enum.any?(states_for(op, rule), &undecided?(&1, op))
    end)
  end

  defp states_for(%Operation{tags: []}, rule), do: [rule.untagged]
  defp states_for(op, rule), do: Enum.map(op.tags, &Map.get(rule.tags, &1))

  defp undecided?(nil, _op), do: true

  defp undecided?(state, op) when is_list(state),
    do: name(op) not in (state[:include] ++ state[:exclude])

  defp undecided?(_state, _op), do: false

  # Where the pruned spec's operations disagree with `rule` — what plain
  # `regen` can see without the source. A partly selected tag rewritten
  # as `:all` leaves no trace here; reading the source catches that.
  @spec check(rule(), [Operation.t()]) :: [String.t()]
  def check(rule, pruned) do
    names = MapSet.new(pruned, &name/1)

    missing =
      for {tag, state} <- states(rule), id <- includes(state), id not in names do
        "#{id} is under `include:` for #{tag}, but not in the pruned spec"
      end

    unselected =
      for op <- pruned, not selected?(op, rule) do
        "#{name(op)} is in the pruned spec, but `tags:` doesn't select it"
      end

    empty =
      for {tag, :all} <- rule.tags, not Enum.any?(pruned, &(tag in &1.tags)) do
        "#{tag} is `:all`, but none of its operations are in the pruned spec"
      end

    missing ++ unselected ++ empty
  end

  defp states(%{tags: tags, untagged: untagged}) do
    Enum.sort(tags) ++ if(untagged, do: [{"untagged", untagged}], else: [])
  end

  defp includes(state) when is_list(state), do: Keyword.fetch!(state, :include)
  defp includes(_state), do: []

  defp selected?(%Operation{tags: []} = op, rule), do: selects?(rule.untagged, op)
  defp selected?(op, rule), do: Enum.any?(op.tags, &selects?(Map.get(rule.tags, &1), op))

  defp selects?(:all, _op), do: true
  defp selects?(state, op) when is_list(state), do: name(op) in Keyword.fetch!(state, :include)
  defp selects?(_state, _op), do: false

  defp state(operations, selected_keys) do
    {include, exclude} = Enum.split_with(operations, &MapSet.member?(selected_keys, key(&1)))

    case {include, exclude} do
      {_include, []} -> :all
      {[], _exclude} -> :none
      _ -> [include: Enum.map(include, &name/1), exclude: Enum.map(exclude, &name/1)]
    end
  end

  defp key(%Operation{method: method, path: path}), do: {method, path}

  defp name(%Operation{operation_id: id}) when is_binary(id), do: id
  defp name(%Operation{id: id}), do: id
end
