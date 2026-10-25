defmodule Hearth.Fs.Ownership do
  @moduledoc false

  # A generated file opts out of regeneration with a moduledoc token:
  #
  #   hearth:owned         → `regen` skips the file entirely
  #   hearth:collaborating → `regen` prompts y/N before overwriting
  #   (no token)           → `regen` overwrites silently
  #
  # Only `@moduledoc` text counts — a spec description copied into a
  # Layer 2 `@doc`, a comment, or a string literal that mentions a token
  # must not change who owns the file. The token is matched as a whole
  # word. `:owned` wins if a moduledoc somehow carries both — the more
  # restrictive intent.
  #
  # A file that doesn't parse can't be scanned by moduledoc, so it falls
  # back to a whole-file scan: a stray token then keeps the file, the
  # safe direction (ownership fails closed).

  @type token :: :owned | :collaborating | :none

  @owned ~r/\bhearth:owned\b/
  @collaborating ~r/\bhearth:collaborating\b/

  @spec classify(binary()) :: token()
  def classify(content) when is_binary(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} -> ast |> moduledocs() |> Enum.join("\n") |> scan()
      {:error, _reason} -> scan(content)
    end
  end

  defp scan(text) do
    cond do
      Regex.match?(@owned, text) -> :owned
      Regex.match?(@collaborating, text) -> :collaborating
      true -> :none
    end
  end

  defp moduledocs(ast) do
    {_ast, docs} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:moduledoc, _, [doc]}]} = node, acc -> {node, [doc_text(doc) | acc]}
        node, acc -> {node, acc}
      end)

    docs
  end

  # A plain or heredoc string, an interpolated one, or a `~S` / `~s`
  # sigil. Anything else (`false`, a function call) has no static text.
  defp doc_text(doc) when is_binary(doc), do: doc
  defp doc_text({:<<>>, _, parts}), do: binary_parts(parts)

  defp doc_text({sigil, _, [{:<<>>, _, parts}, _mods]}) when sigil in [:sigil_S, :sigil_s],
    do: binary_parts(parts)

  defp doc_text(_doc), do: ""

  defp binary_parts(parts), do: parts |> Enum.filter(&is_binary/1) |> Enum.join()
end
