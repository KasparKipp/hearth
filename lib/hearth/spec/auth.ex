defmodule Hearth.Spec.Auth do
  @moduledoc false

  # Reduces an OpenAPI spec's security configuration to the single auth
  # strategy the Layer 1 renderer knows how to wire:
  #
  #   * `:none`                    — no security schemes defined
  #   * `:bearer`                  — HTTP bearer token
  #   * `{:api_key, :header, name}` — API key sent in a request header
  #   * `{:api_key, :query, name}`  — API key sent as a query parameter
  #   * `{:unsupported, type}`     — oauth2 / openIdConnect / http-basic /
  #                                  anything else; the renderer leaves a
  #                                  TODO comment instead of guessing
  #
  # v1 picks one strategy per integration. When a spec defines several
  # schemes the primary one is: the first scheme named by the top-level
  # `security` requirement, else the first defined scheme by name order.
  #
  # TODO (multi-scheme selection): auto-picking is a v1 shortcut. When a
  # spec defines several schemes, `mix hearth.gen` should prompt the
  # user to choose. A `--auth-scheme <name>` flag selects one
  # non-interactively; under `--yes` with multiple schemes and no
  # `--auth-scheme`, the task must halt with an error rather than guess.

  @type strategy ::
          :none
          | :bearer
          | {:api_key, :header | :query, String.t()}
          | {:unsupported, String.t()}

  @spec strategy(map()) :: strategy()
  def strategy(spec) when is_map(spec) do
    schemes = get_in(spec, ["components", "securitySchemes"]) || %{}

    case primary_scheme(spec, schemes) do
      nil -> :none
      scheme -> classify(scheme)
    end
  end

  defp primary_scheme(_spec, schemes) when map_size(schemes) == 0, do: nil

  defp primary_scheme(spec, schemes) do
    named = spec |> Map.get("security", []) |> first_named_scheme()

    if is_binary(named) and is_map(schemes[named]) do
      schemes[named]
    else
      schemes |> Enum.sort() |> List.first() |> elem(1)
    end
  end

  defp first_named_scheme([requirement | _rest]) when is_map(requirement) do
    requirement |> Map.keys() |> List.first()
  end

  defp first_named_scheme(_security), do: nil

  defp classify(%{"type" => "http", "scheme" => scheme}) when is_binary(scheme) do
    if String.downcase(scheme) == "bearer" do
      :bearer
    else
      {:unsupported, "http/#{scheme}"}
    end
  end

  defp classify(%{"type" => "apiKey", "in" => "header", "name" => name}) when is_binary(name) do
    {:api_key, :header, name}
  end

  defp classify(%{"type" => "apiKey", "in" => "query", "name" => name}) when is_binary(name) do
    {:api_key, :query, name}
  end

  defp classify(%{"type" => type}) when is_binary(type), do: {:unsupported, type}

  defp classify(_scheme), do: {:unsupported, "unknown"}
end
