defmodule Hearth.Config.Literal do
  @moduledoc false

  # Reads `.hearth.exs` as data: the file is parsed, never evaluated, and
  # only literals come back — lists, keyword lists, maps, strings, atoms,
  # numbers (a leading `-` too), tuples and module names. Anything that
  # would run — a call, a variable, a sigil, interpolation, an attribute —
  # is an error naming its line, so nothing in the file executes. Pure.

  @spec read(String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def read(content, path) do
    case Code.string_to_quoted(content, file: path) do
      {:ok, {:__block__, _meta, []}} -> {:ok, nil}
      {:ok, {:__block__, _meta, [_, _ | _]}} -> {:error, "#{path} holds one keyword list."}
      {:ok, quoted} -> literal(quoted, path)
      {:error, {meta, message, token}} -> {:error, syntax_message(path, meta, message, token)}
    end
  end

  defp literal(quoted, path) do
    {:ok, value(quoted)}
  catch
    {:not_literal, node} -> {:error, not_literal_message(path, node)}
  end

  defp value(term) when is_atom(term) or is_binary(term) or is_number(term), do: term
  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value({left, right}), do: {value(left), value(right)}
  defp value({:{}, _meta, elements}), do: elements |> Enum.map(&value/1) |> List.to_tuple()
  defp value({:%{}, _meta, pairs}), do: Map.new(pairs, &value/1)
  defp value({:-, _meta, [number]}) when is_number(number), do: -number

  defp value({:__aliases__, _meta, segments} = node) do
    if Enum.all?(segments, &is_atom/1),
      do: Module.concat(segments),
      else: throw({:not_literal, node})
  end

  defp value({:__block__, _meta, [single]}), do: value(single)
  defp value(node), do: throw({:not_literal, node})

  defp not_literal_message(path, node) do
    line = with {_name, meta, _args} when is_list(meta) <- node, do: meta[:line]
    code = node |> Macro.to_string() |> String.slice(0, 60)

    "#{path}#{if is_integer(line), do: ":#{line}"}: `#{code}` isn't plain data. " <>
      "#{path} holds literals only — lists, keyword lists, maps, strings, atoms, " <>
      "numbers, tuples and module names — and nothing in it runs."
  end

  defp syntax_message(path, meta, message, token) do
    message = if is_tuple(message), do: Tuple.to_list(message) |> Enum.join(), else: message
    "#{path}:#{meta[:line]}: #{message}#{token}"
  end
end
