defmodule Hearth.Registry do
  @moduledoc false

  # Curated map of registry shortcuts → canonical OpenAPI spec URLs.
  #
  # Shape:
  #
  #     %{
  #       "<shortcut>" => %{
  #         "latest"     => "<url to current spec>",
  #         "<version>"  => "<url to pinned historic spec>"
  #       }
  #     }
  #
  # Conventions:
  #
  #   * Each shortcut MUST have a `"latest"` key. Bare `mix hearth.gen <name>`
  #     resolves to `<name>@latest`.
  #   * Version strings are free-form ISO-like dates ("2024-01-01") or vendor
  #     version tags. They sort lexicographically with `"latest"` pinned to
  #     the front.
  #   * Integration module names are derived from the shortcut via
  #     `Macro.camelize/1`. So `"stripe" → "Stripe"`, `"google_docs" →
  #     "GoogleDocs"`, `"aws_s3" → "AwsS3"`. No need to maintain a parallel
  #     name list.
  #
  # New entries are accepted on two conditions:
  #
  #   1. URL is the vendor's own canonical publication (not a community
  #      mirror) AND responds 200 at a stable path.
  #   2. The spec is small enough that naive decode won't blow up.
  #
  # Lookup is case-insensitive — Hearth.Spec.Source.resolve/1 normalizes
  # registry inputs to lowercase before they reach here.

  @entries %{
    "stripe" => %{
      "latest" =>
        "https://raw.githubusercontent.com/stripe/openapi/refs/heads/master/latest/openapi.spec3.yaml"
    }
  }

  @type entry :: %{
          name: String.t(),
          version: String.t(),
          url: String.t(),
          integration: String.t()
        }

  @type lookup_error ::
          {:unknown_name, String.t()}
          | {:unknown_version, name :: String.t(), version :: String.t(),
             available :: [String.t()]}

  @spec lookup(String.t()) :: {:ok, entry()} | {:error, lookup_error()}
  def lookup(input) when is_binary(input) do
    {name, version} = parse(input)

    case Map.get(@entries, name) do
      nil ->
        {:error, {:unknown_name, name}}

      versions ->
        case Map.get(versions, version) do
          nil ->
            {:error, {:unknown_version, name, version, sort_versions(versions)}}

          url ->
            {:ok,
             %{
               name: name,
               version: version,
               url: url,
               integration: Macro.camelize(name)
             }}
        end
    end
  end

  @spec list() :: [String.t()]
  def list, do: @entries |> Map.keys() |> Enum.sort()

  @spec versions(String.t()) :: [String.t()] | nil
  def versions(name) when is_binary(name) do
    case Map.get(@entries, name) do
      nil -> nil
      versions -> sort_versions(versions)
    end
  end

  defp parse(input) do
    case String.split(input, "@", parts: 2) do
      [name] -> {name, "latest"}
      [name, version] -> {name, version}
    end
  end

  # "latest" sorts first; historical versions follow in descending order
  # so the newest pinned version is right after latest.
  defp sort_versions(versions) do
    versions
    |> Map.keys()
    |> Enum.sort(fn
      "latest", _ -> true
      _, "latest" -> false
      a, b -> a >= b
    end)
  end
end
