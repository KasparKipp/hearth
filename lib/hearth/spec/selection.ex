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
