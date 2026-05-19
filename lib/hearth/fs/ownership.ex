defmodule Hearth.Fs.Ownership do
  @moduledoc false

  # A generated file opts out of regeneration with a moduledoc token:
  #
  #   hearth:owned         → `regen` skips the file entirely
  #   hearth:collaborating → `regen` prompts y/N before overwriting
  #   (no token)           → `regen` overwrites silently
  #
  # The token is matched as a whole word anywhere in the file. By
  # convention it lives in the moduledoc, but a whole-file scan is
  # simpler and the token strings are distinctive enough not to
  # false-match. `:owned` wins if a file somehow carries both — the
  # more restrictive intent.

  @type token :: :owned | :collaborating | :none

  @owned ~r/\bhearth:owned\b/
  @collaborating ~r/\bhearth:collaborating\b/

  @spec classify(binary()) :: token()
  def classify(content) when is_binary(content) do
    cond do
      Regex.match?(@owned, content) -> :owned
      Regex.match?(@collaborating, content) -> :collaborating
      true -> :none
    end
  end
end
