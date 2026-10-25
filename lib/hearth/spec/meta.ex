defmodule Hearth.Spec.Meta do
  @moduledoc false

  # Hearth's own metadata, stored in the pruned spec under the
  # `x-hearth` extension key (valid at the top level of any OpenAPI
  # document). `mix hearth.gen` writes it; `mix hearth.regen` reads it
  # back so regeneration reproduces gen's choices instead of
  # recomputing them from the pruned subset:
  #
  #   * `base_path` — the path prefix gen folded into Layer 1's base
  #     URL (and into the `config/test.exs` base URL). Recomputed from
  #     the subset, it can come out longer and desync from that config.
  #   * `source` — the spec gen was run on, shown in Layer 2's moduledoc.
  #
  # Readers return `nil` when the block is absent (an integration
  # generated before it existed) or malformed; callers fall back.

  @key "x-hearth"

  @spec put(map(), keyword()) :: map()
  def put(spec, opts) when is_map(spec) do
    Map.put(spec, @key, %{
      "base_path" => Keyword.fetch!(opts, :base_path),
      "source" => Keyword.fetch!(opts, :source)
    })
  end

  @spec base_path(map()) :: String.t() | nil
  def base_path(spec), do: string_field(spec, "base_path")

  @spec source(map()) :: String.t() | nil
  def source(spec), do: string_field(spec, "source")

  defp string_field(spec, field) do
    case spec do
      %{@key => %{^field => value}} when is_binary(value) -> value
      _ -> nil
    end
  end
end
