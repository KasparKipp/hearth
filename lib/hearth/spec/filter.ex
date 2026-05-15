defmodule Hearth.Spec.Filter do
  @moduledoc false

  # Parses the `--tags` CLI string into a filter and applies it to a
  # list of `Hearth.Spec.Operation` structs.
  #
  # The `--tags` syntax is three-level delimited:
  #
  #   * `;` separates tag-specs
  #   * `:` separates a tag name from its operationId allowlist
  #   * `,` separates operationIds
  #
  # `"Customers;Subscriptions:create_subscription,list_subscriptions"`
  # keeps every operation tagged *Customers*, plus the two named
  # operations tagged *Subscriptions*. A bare tag name (no colon) means
  # "all operations under that tag". operationIds match against an
  # operation's derived `:id` (the snake_case function name).
  #
  # Tag names containing `;`, `:`, or `,` are not addressable through
  # the flag — a future config-file mechanism covers those.

  alias Hearth.Spec.Operation

  @type rule :: {tag :: String.t(), :all | {:only, [String.t()]}}
  @type t :: :all | [rule()]

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:error, "empty --tags filter"}

      trimmed ->
        trimmed
        |> String.split(";", trim: true)
        |> parse_rules([])
    end
  end

  @spec apply([Operation.t()], t()) :: [Operation.t()]
  def apply(operations, :all), do: operations

  def apply(operations, rules) when is_list(rules) do
    Enum.filter(operations, fn op -> Enum.any?(rules, &matches?(op, &1)) end)
  end

  defp parse_rules([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_rules([segment | rest], acc) do
    case parse_rule(segment) do
      {:ok, rule} -> parse_rules(rest, [rule | acc])
      {:error, _reason} = error -> error
    end
  end

  defp parse_rule(segment) do
    case String.split(segment, ":", parts: 2) do
      [tag] -> parse_bare_tag(tag)
      [tag, ids] -> parse_narrowed_tag(tag, ids)
    end
  end

  defp parse_bare_tag(tag) do
    with {:ok, name} <- non_empty_tag(tag), do: {:ok, {name, :all}}
  end

  defp parse_narrowed_tag(tag, ids) do
    with {:ok, name} <- non_empty_tag(tag) do
      case split_ids(ids) do
        [] -> {:error, "tag #{inspect(name)} has a colon but no operationIds after it"}
        id_list -> {:ok, {name, {:only, id_list}}}
      end
    end
  end

  defp non_empty_tag(tag) do
    case String.trim(tag) do
      "" -> {:error, "empty tag name in --tags"}
      name -> {:ok, name}
    end
  end

  defp split_ids(ids) do
    ids
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp matches?(%Operation{tags: tags}, {tag, :all}), do: tag in tags

  defp matches?(%Operation{tags: tags, id: id}, {tag, {:only, ids}}) do
    tag in tags and id in ids
  end
end
