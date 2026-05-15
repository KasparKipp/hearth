defmodule Hearth.Spec.Source do
  @moduledoc false

  # Classifies a `mix hearth.gen <source>` argument into one of three input
  # shapes the rest of the pipeline knows how to handle:
  #
  #   * `{:url, url}`      — an http(s) URL.
  #   * `{:file, path}`    — a local path on disk.
  #   * `{:registry, name}` — a curated shorthand handled by `Hearth.Registry`.
  #
  # The function is pure: no I/O, no filesystem checks. Whether the file
  # actually exists, the URL is reachable, or the registry has the entry is
  # the next layer's problem.

  @file_extensions ~w(.yaml .yml .json)
  # Registry names may include `@` for `name@version` syntax and `.` for
  # vendor-style version tags. Must start with an alphanumeric so that
  # `@latest` (with no name) and `.something` (which looks path-like)
  # never accidentally match.
  @registry_pattern ~r/^[a-zA-Z0-9][a-zA-Z0-9_@.\-]*$/

  @type t ::
          {:url, String.t()}
          | {:file, Path.t()}
          | {:registry, String.t()}

  @spec resolve(String.t()) :: t() | {:error, String.t()}
  def resolve(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        {:error, "empty source"}

      String.starts_with?(trimmed, ["http://", "https://"]) ->
        {:url, trimmed}

      file_like?(trimmed) ->
        {:file, trimmed}

      Regex.match?(@registry_pattern, trimmed) ->
        {:registry, String.downcase(trimmed)}

      true ->
        {:error,
         "could not classify #{inspect(input)} — expected an http(s) URL, " <>
           "a file path (contains `/`, starts with `.`, or ends in " <>
           ".yaml/.yml/.json), or a registry shorthand " <>
           "(e.g. `stripe` or `stripe@latest`)"}
    end
  end

  defp file_like?(input) do
    String.contains?(input, "/") or
      String.starts_with?(input, ".") or
      Enum.any?(@file_extensions, &String.ends_with?(input, &1))
  end
end
