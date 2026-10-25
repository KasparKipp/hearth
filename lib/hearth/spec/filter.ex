defmodule Hearth.Spec.Filter do
  @moduledoc false

  # Parses the repeatable `--tag` CLI flag into a filter and applies it
  # to a list of `Hearth.Spec.Operation` structs.
  #
  # `--tag` is repeatable — one tag-spec per occurrence, no in-string
  # delimiter. `parse/1` takes the list of `--tag` values the CLI
  # collected. Within a single value, the FIRST `:` separates the tag
  # name from a comma-separated operationId allowlist:
  #
  #   "Customers"                          -> every op tagged Customers
  #   "Subscriptions:create_sub,list_sub"  -> only those two Subscription ops
  #
  # operationIds match against an operation's derived `:id` (the
  # snake_case function name). User-supplied ids are sanitized the same
  # way `:id` is derived, so an id copied straight from the spec —
  # camelCase (`getBoard`) or hyphenated (`get-board`) — still matches.
  # Tag names may contain commas, semicolons, and spaces — only `:` is
  # reserved (the first one delimits). A `:` in the operationId portion
  # is a user error (a comma was almost certainly meant) and is
  # rejected. Tag names containing `:` are not addressable through the
  # flag — a future config-file concern.
  #
  # Repeated specs for the same tag are merged into a single rule that
  # keeps the tag's first-occurrence position. `:only` id-lists union
  # and sort; a narrowing `:only` anywhere for a tag wins over a bare
  # `:all` for that same tag.

  alias Hearth.Spec.Operation

  @type rule :: {tag :: String.t(), :all | {:only, [String.t()]}}
  @type t :: :all | [rule()]

  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse([]), do: {:error, "no --tag given"}

  def parse(values) when is_list(values) do
    values
    |> parse_each([])
    |> merge_parsed()
  end

  @spec apply([Operation.t()], t()) :: [Operation.t()]
  def apply(operations, :all), do: operations

  def apply(operations, rules) when is_list(rules) do
    Enum.filter(operations, fn op -> Enum.any?(rules, &matches?(op, &1)) end)
  end

  defp parse_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_each([value | rest], acc) do
    case parse_one(value) do
      {:ok, rule} -> parse_each(rest, [rule | acc])
      {:error, _reason} = error -> error
    end
  end

  defp parse_one(value) do
    case String.split(value, ":", parts: 2) do
      [tag] -> parse_bare_tag(tag)
      [tag, ids] -> parse_narrowed_tag(tag, ids)
    end
  end

  defp parse_bare_tag(tag) do
    with {:ok, name} <- non_empty_tag(tag), do: {:ok, {name, :all}}
  end

  defp parse_narrowed_tag(tag, ids) do
    with {:ok, name} <- non_empty_tag(tag),
         {:ok, id_list} <- parse_ids(name, ids) do
      {:ok, {name, {:only, id_list}}}
    end
  end

  defp non_empty_tag(tag) do
    case String.trim(tag) do
      "" -> {:error, "empty tag name in --tag"}
      name -> {:ok, name}
    end
  end

  # The id portion is everything after the FIRST `:`.
  defp parse_ids(tag, ids) do
    if stray_colon?(ids) do
      {:error,
       ~s(tag "#{tag}": operationIds are comma-separated; found a stray ) <>
         ~s(":" in "#{ids}" — did you mean "#{tag}:#{String.replace(ids, ":", ",")}"?)}
    else
      case sanitized_ids(ids) do
        [] -> {:error, ~s(tag "#{tag}" has a colon but no operationIds after it)}
        id_list -> {:ok, id_list}
      end
    end
  end

  # A `:` in the id portion is a stray delimiter (a comma typo) only
  # when there is real content around it. `Customers::` — an id portion
  # that is nothing but `:` and `,` and whitespace — is an empty list,
  # not a typo, and falls through to the "no operationIds" message.
  defp stray_colon?(ids) do
    String.contains?(ids, ":") and String.replace(ids, ~r/[\s,:]/, "") != ""
  end

  # Splits on commas and normalizes each operationId the same way
  # `Operation` derives `:id` — so an id copied straight out of the
  # spec (camelCase, hyphenated) still matches. Empties drop, dups
  # collapse.
  defp sanitized_ids(ids) do
    ids
    |> String.split(",", trim: true)
    |> Enum.map(&Operation.function_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp merge_parsed({:error, _reason} = error), do: error
  defp merge_parsed({:ok, rules}), do: {:ok, merge_rules(rules)}

  # Collapses repeated specs for the same tag into one rule, keeping the
  # tag's first-occurrence position. If every spec for a tag is `:all`,
  # the merged rule stays `:all`; if any spec narrows with `:only`, the
  # merged rule is `{:only, <sorted union of every :only id-list>}` —
  # a present `:only` always wins over a bare `:all` for that tag.
  defp merge_rules(rules) do
    rules
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn tag ->
      specs = for {rule_tag, spec} <- rules, rule_tag == tag, do: spec
      {tag, merge_specs(specs)}
    end)
  end

  defp merge_specs(specs) do
    only_ids =
      Enum.flat_map(specs, fn
        :all -> []
        {:only, ids} -> ids
      end)

    case only_ids do
      [] -> :all
      ids -> {:only, ids |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp matches?(%Operation{tags: tags}, {tag, :all}), do: tag in tags

  defp matches?(%Operation{tags: tags, id: id}, {tag, {:only, ids}}) do
    tag in tags and id in ids
  end
end
