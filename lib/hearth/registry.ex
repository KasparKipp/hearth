defmodule Hearth.Registry do
  @moduledoc false

  # Curated map of registry shortcuts → canonical OpenAPI spec URLs.
  #
  # Shape:
  #
  #     %{
  #       "<shortcut>" => %{
  #         "<version>" => "<url to spec>",
  #         "<alias>"   => {:alias, "<other-version>"}
  #       }
  #     }
  #
  # Conventions:
  #
  #   * Each shortcut MUST have a `"latest"` key (real URL or alias chain
  #     terminating in one). Bare `mix hearth.gen <name>` resolves to
  #     `<name>@latest`.
  #   * Version strings are free-form: ISO-like dates ("2026-04-22"),
  #     vendor codenames ("dahlia"), or both joined with a dot
  #     ("2026-04-22.dahlia"). They sort lexicographically with
  #     `"latest"` pinned to the front.
  #   * Aliases (`{:alias, "<target>"}`) point at another version key in
  #     the same shortcut. The lookup follows the chain to the URL.
  #     Aliases save us from duplicating URLs across synonyms (Stripe
  #     publishes each release under both a date and a codename, and the
  #     two together). When a new Stripe spec drops, only the `"latest"`
  #     URL changes, the old codename gets repointed at its archived URL,
  #     and the date/codename synonyms come along for the ride.
  #   * Integration module names are derived from the shortcut via
  #     `Macro.camelize/1`. So `"stripe" → "Stripe"`, `"google_docs" →
  #     "GoogleDocs"`, `"aws_s3" → "AwsS3"`. No parallel name list.
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
      # The canonical key for each Stripe release is the full
      # `<date>.<codename>` form — that is where the URL actually lives.
      # All shorter forms (date alone, codename alone) and the floating
      # `"latest"` pointer are aliases that resolve to it.
      #
      # Why canonicalize on the most specific form: when Stripe ships
      # their next release, only `"latest"` needs to be repointed at the
      # new key. Today's date/codename aliases automatically follow this
      # release into the historic record without any further edits.
      #
      # Promoting a new release looks like:
      #
      #   1. Add `"<new_date>.<new_codename>" => "<new_url>"`.
      #   2. Add aliases `"<new_codename>"` and `"<new_date>"` for that key.
      #   3. Repoint `"latest"` at the new key.
      #   4. Update the previous release's canonical URL to a pinned
      #      historic location (probably a commit SHA in the stripe/openapi
      #      repo) so the spec doesn't drift.
      "2026-04-22.dahlia" =>
        "https://raw.githubusercontent.com/stripe/openapi/refs/heads/master/latest/openapi.spec3.yaml",
      "latest" => {:alias, "2026-04-22.dahlia"},
      "dahlia" => {:alias, "2026-04-22.dahlia"},
      "2026-04-22" => {:alias, "2026-04-22.dahlia"}
    }
  }

  @type entry :: %{
          name: String.t(),
          version: String.t(),
          resolved_version: String.t(),
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
        case follow_alias(versions, version) do
          {:ok, resolved, url} ->
            {:ok,
             %{
               name: name,
               version: version,
               resolved_version: resolved,
               url: url,
               integration: Macro.camelize(name)
             }}

          :unknown ->
            {:error, {:unknown_version, name, version, sort_versions(versions)}}
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

  # Walks `{:alias, target}` chains down to the version key that holds
  # a real URL. Returns the resolved version key alongside the URL so
  # callers can show "(alias for stripe@latest)" in user-facing output.
  defp follow_alias(versions, version) do
    case Map.get(versions, version) do
      nil -> :unknown
      {:alias, target} -> follow_alias(versions, target)
      url when is_binary(url) -> {:ok, version, url}
    end
  end

  # "latest" sorts first; the rest sort descending so the newest pinned
  # version sits closest to "latest" once historic entries exist.
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
