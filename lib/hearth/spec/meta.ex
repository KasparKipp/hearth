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
  #   * `module` — the integration's Layer 1 module. `regen` derives
  #     every other module from it, so the domain gen chose survives.
  #
  # Readers return `nil` when the block is absent (an integration
  # generated before it existed) or malformed. `regen` falls back for
  # `base_path` and `source`, and halts without `module`.

  @key "x-hearth"

  @spec put(map(), keyword()) :: map()
  def put(spec, opts) when is_map(spec) do
    Map.put(spec, @key, %{
      "base_path" => Keyword.fetch!(opts, :base_path),
      "source" => Keyword.fetch!(opts, :source),
      "module" => Keyword.fetch!(opts, :module)
    })
  end

  @spec base_path(map()) :: String.t() | nil
  def base_path(spec), do: string_field(spec, "base_path")

  @spec source(map()) :: String.t() | nil
  def source(spec), do: string_field(spec, "source")

  @spec module(map()) :: String.t() | nil
  def module(spec), do: string_field(spec, "module")

  # Points `x-hearth.module` at `module` in the pruned spec's YAML
  # text, editing only that value so hand-edits and formatting
  # survive. When the current value can't be matched exactly once (an
  # unusual quoting style), the decoded spec is re-encoded instead.
  @spec replace_module(String.t(), map(), String.t()) :: String.t()
  def replace_module(yaml, spec, module) do
    regex = ~r/(\bmodule:[ \t]*["']?)#{Regex.escape(module(spec) || "")}(?![\w.])/

    case Regex.scan(regex, yaml) do
      [_] -> Regex.replace(regex, yaml, "\\1#{module}")
      _ -> spec |> put_in([@key, "module"], module) |> Hearth.Spec.Prune.to_yaml()
    end
  end

  defp string_field(spec, field) do
    case spec do
      %{@key => %{^field => value}} when is_binary(value) -> value
      _ -> nil
    end
  end
end
