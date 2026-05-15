defmodule Hearth.Spec.Loader do
  @moduledoc false

  # Decodes OpenAPI spec bytes into a generic Elixir map.
  #
  # The format is sniffed from the file extension (or URL path) and the
  # decode itself is dispatched to the right parser:
  #
  #   * `:yaml` → `YamlElixir.read_from_string/1`
  #   * `:json` → `JSON.decode/1` (Erlang/OTP 27+ stdlib via Elixir 1.18+)
  #
  # No `$ref` resolution, no `allOf` flattening — that is the step-5
  # renderer's concern. The loader returns whatever shape the spec
  # has on disk.

  @yaml_extensions ~w(.yaml .yml)
  @json_extensions ~w(.json)

  @type format :: :yaml | :json
  @type sniff_result :: format() | :unknown

  @spec sniff(String.t()) :: sniff_result()
  def sniff(path_or_url) when is_binary(path_or_url) do
    extension =
      path_or_url
      |> strip_query()
      |> Path.extname()
      |> String.downcase()

    cond do
      extension in @yaml_extensions -> :yaml
      extension in @json_extensions -> :json
      true -> :unknown
    end
  end

  @spec decode(binary(), format()) :: {:ok, term()} | {:error, term()}
  def decode(bytes, :yaml) when is_binary(bytes) do
    YamlElixir.read_from_string(bytes)
  end

  def decode(bytes, :json) when is_binary(bytes) do
    JSON.decode(bytes)
  end

  defp strip_query(path_or_url) do
    path_or_url
    |> String.split("?", parts: 2)
    |> hd()
  end
end
