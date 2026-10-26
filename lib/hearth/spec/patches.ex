defmodule Hearth.Spec.Patches do
  @moduledoc false

  # `overrides: [patches: …]` — edits to the spec document, each a JSON
  # pointer (RFC 6901) mapped to the value to put there:
  #
  #     patches: %{
  #       "/components/securitySchemes/bearerAuth" => %{"type" => "http", "scheme" => "bearer"},
  #       "/security" => [%{"bearerAuth" => []}],
  #       "/paths/~1items/get/deprecated" => nil
  #     }
  #
  # A value replaces whatever is there; maps missing on the way are
  # created. `nil` removes the key (or list item). In a list, a segment
  # is an existing index, or `-` to append. Pointers address the
  # OpenAPI 3 form of the spec, and apply in pointer order, so
  # `"/security/-"` appends to what `"/security"` set.
  #
  # A patch the source already satisfies — the value is there, or the
  # key to remove isn't — is returned as stale. Pure.

  @type patch :: {String.t(), [String.t()], term()}
  @type stale :: {:patches, String.t()}

  @spec parse(term()) :: {:ok, [patch()]} | {:error, String.t()}
  def parse(patches) when is_map(patches) do
    patches
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {pointer, value}, {:ok, acc} ->
      case parse_patch(pointer, value) do
        {:ok, patch} -> {:cont, {:ok, [patch | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  def parse(_patches), do: {:error, shape_message()}

  defp parse_patch("/" <> rest = pointer, value) do
    if json?(value),
      do: {:ok, {pointer, rest |> String.split("/") |> Enum.map(&unescape/1), value}},
      else: {:error, value_message(pointer)}
  end

  defp parse_patch(pointer, _value) do
    {:error,
     "`overrides: [patches: …]` key #{inspect(pointer)} isn't a JSON pointer — " <>
       ~s|it starts with "/", e.g. "/components/securitySchemes/bearerAuth".|}
  end

  defp unescape(segment), do: segment |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp json?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp json?(nil), do: true
  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)

  defp json?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json?(value) end)

  defp json?(_value), do: false

  # The patched spec and the stale patches, or an error when a pointer
  # can't be followed.
  @spec apply(map(), [patch()]) :: {:ok, map(), [stale()]} | {:error, String.t()}
  def apply(spec, patches) do
    Enum.reduce_while(patches, {:ok, spec, []}, fn {pointer, segments, value},
                                                   {:ok, acc, stale} ->
      case patch(acc, segments, value) do
        {:ok, acc} ->
          {:cont, {:ok, acc, stale}}

        {:stale, why} ->
          {:cont, {:ok, acc, stale ++ [{:patches, "#{inspect(pointer)} (#{why})"}]}}

        {:error, why} ->
          {:halt, {:error, error_message(pointer, why)}}
      end
    end)
  end

  defp patch(spec, segments, value) do
    case fetch(spec, segments) do
      {:ok, ^value} when not is_nil(value) -> {:stale, "already in the source"}
      :error when is_nil(value) -> {:stale, "nothing to remove"}
      _ -> put(spec, segments, value, [])
    end
  end

  defp fetch(value, []), do: {:ok, value}

  defp fetch(map, [segment | rest]) when is_map(map) do
    case Map.fetch(map, segment) do
      {:ok, child} -> fetch(child, rest)
      :error -> :error
    end
  end

  defp fetch(list, [segment | rest]) when is_list(list) do
    case index(list, segment) do
      {:ok, i} -> list |> Enum.at(i) |> fetch(rest)
      _ -> :error
    end
  end

  defp fetch(_value, _segments), do: :error

  # `path` is the segments walked so far, for error messages.
  defp put(map, [segment], nil, _path) when is_map(map), do: {:ok, Map.delete(map, segment)}
  defp put(map, [segment], value, _path) when is_map(map), do: {:ok, Map.put(map, segment, value)}

  defp put(map, [segment | rest], value, path) when is_map(map) do
    with {:ok, child} <- put(Map.get(map, segment, %{}), rest, value, [segment | path]) do
      {:ok, Map.put(map, segment, child)}
    end
  end

  defp put(list, [segment | rest], value, path) when is_list(list) do
    case {index(list, segment), rest, value} do
      {:append, [], value} -> {:ok, list ++ [value]}
      {{:ok, i}, [], nil} -> {:ok, List.delete_at(list, i)}
      {{:ok, i}, [], value} -> {:ok, List.replace_at(list, i, value)}
      {{:ok, i}, rest, value} -> put_at(list, i, rest, value, [segment | path])
      _ -> {:error, "#{inspect(pointer(path))} has no item #{segment}"}
    end
  end

  defp put(other, _segments, _value, path),
    do: {:error, "#{inspect(pointer(path))} is #{kind(other)}"}

  defp put_at(list, i, rest, value, path) do
    with {:ok, child} <- put(Enum.at(list, i), rest, value, path) do
      {:ok, List.replace_at(list, i, child)}
    end
  end

  defp index(_list, "-"), do: :append

  defp index(list, segment) do
    case Integer.parse(segment) do
      {i, ""} when i >= 0 and i < length(list) -> {:ok, i}
      _ -> :error
    end
  end

  defp pointer(path) do
    Enum.map_join(Enum.reverse(path), fn segment ->
      "/" <> (segment |> String.replace("~", "~0") |> String.replace("/", "~1"))
    end)
  end

  defp kind(value) when is_binary(value), do: "a string"
  defp kind(value) when is_number(value), do: "a number"
  defp kind(value) when is_boolean(value), do: "a boolean"
  defp kind(nil), do: "null"

  defp error_message(pointer, why),
    do: "`overrides: [patches: …]` can't set #{inspect(pointer)}: #{why}."

  defp value_message(pointer) do
    "`overrides: [patches: …]` value for #{inspect(pointer)} isn't JSON — use maps with " <>
      ~s|string keys, lists, strings, numbers, true, false and nil, e.g. %{"type" => "http"}.|
  end

  defp shape_message do
    "`overrides: [patches: …]` maps JSON pointers to values, e.g. " <>
      ~s|`patches: %{"/security" => [%{"bearerAuth" => []}]}`.|
  end
end
