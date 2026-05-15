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
      # === Stripe registry layout ===
      #
      # `latest` is a separate canonical entry pointing at Stripe's
      # floating master URL — drifts as Stripe pushes. Use it when you
      # want auto-tracking; use a dated form when you want reproducibility.
      #
      # Each dated `<date>.<codename>` entry holds an immutable tagged URL
      # (e.g. v2266). The codename-alone alias (`dahlia`, `clover`, …)
      # resolves to the MOST RECENT dated release in that codename family,
      # so `stripe@dahlia` tracks the dahlia family's latest. Date-alone
      # aliases (`2026-04-22`) resolve to the exact `<date>.<codename>`
      # they correspond to.
      #
      # Source for the historic URLs: cloned stripe/openapi with
      # `--filter=blob:none`, mapped each of the v1..v2266 tags to its
      # `openapi/spec3.yaml` blob, grouped tags by the spec's `info.version`
      # field, and picked the highest tag per version (i.e. the most
      # recently-published spec snapshot for that public API date).
      #
      # Coverage is currently the three active codenames — basil, clover,
      # dahlia. Earlier codenames (acacia and before) are skipped; add
      # them if a user pins back that far.
      #
      # Promoting a new Stripe release:
      #   1. Add a `<new_date>.<new_codename>` canonical entry with its
      #      tag URL.
      #   2. Add a `<new_date>` alias pointing at it.
      #   3. If the codename matches an existing family, repoint the
      #      codename alias to the new date. If it's a new codename, add
      #      a new codename alias.
      #   4. `latest` keeps the master URL — no edit needed there.

      # Floating pointer (master/HEAD).
      "latest" =>
        "https://raw.githubusercontent.com/stripe/openapi/refs/heads/master/openapi/spec3.yaml",

      # --- dahlia ---
      "2026-04-22.dahlia" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2266/openapi/spec3.yaml",
      "2026-03-25.dahlia" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2248/openapi/spec3.yaml",
      "dahlia" => {:alias, "2026-04-22.dahlia"},
      "2026-04-22" => {:alias, "2026-04-22.dahlia"},
      "2026-03-25" => {:alias, "2026-03-25.dahlia"},

      # --- clover ---
      "2026-02-25.clover" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2203/openapi/spec3.yaml",
      "2026-01-28.clover" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2182/openapi/spec3.yaml",
      "2025-12-15.clover" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2139/openapi/spec3.yaml",
      "2025-11-17.clover" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2132/openapi/spec3.yaml",
      "2025-10-29.clover" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2110/openapi/spec3.yaml",
      "2025-09-30.clover" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2092/openapi/spec3.yaml",
      "clover" => {:alias, "2026-02-25.clover"},
      "2026-02-25" => {:alias, "2026-02-25.clover"},
      "2026-01-28" => {:alias, "2026-01-28.clover"},
      "2025-12-15" => {:alias, "2025-12-15.clover"},
      "2025-11-17" => {:alias, "2025-11-17.clover"},
      "2025-10-29" => {:alias, "2025-10-29.clover"},
      "2025-09-30" => {:alias, "2025-09-30.clover"},

      # --- basil ---
      "2025-08-27.basil" =>
        "https://raw.githubusercontent.com/stripe/openapi/v2017/openapi/spec3.yaml",
      "2025-07-30.basil" =>
        "https://raw.githubusercontent.com/stripe/openapi/v1927/openapi/spec3.yaml",
      "2025-06-30.basil" =>
        "https://raw.githubusercontent.com/stripe/openapi/v1867/openapi/spec3.yaml",
      "2025-05-28.basil" =>
        "https://raw.githubusercontent.com/stripe/openapi/v1818/openapi/spec3.yaml",
      "2025-04-30.basil" =>
        "https://raw.githubusercontent.com/stripe/openapi/v1769/openapi/spec3.yaml",
      "2025-03-31.basil" =>
        "https://raw.githubusercontent.com/stripe/openapi/v1712/openapi/spec3.yaml",
      "basil" => {:alias, "2025-08-27.basil"},
      "2025-08-27" => {:alias, "2025-08-27.basil"},
      "2025-07-30" => {:alias, "2025-07-30.basil"},
      "2025-06-30" => {:alias, "2025-06-30.basil"},
      "2025-05-28" => {:alias, "2025-05-28.basil"},
      "2025-04-30" => {:alias, "2025-04-30.basil"},
      "2025-03-31" => {:alias, "2025-03-31.basil"}
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
            {:error, {:unknown_version, name, version, canonical_versions(versions)}}
        end
    end
  end

  @spec list() :: [String.t()]
  def list, do: @entries |> Map.keys() |> Enum.sort()

  # Lists only canonical versions (those backed by a URL). Aliases
  # resolve at lookup time but are invisible to listings — surfacing
  # them confuses users who expect "available versions" to be the
  # source of truth, and aliases are convenience plumbing on top.
  @spec versions(String.t()) :: [String.t()] | nil
  def versions(name) when is_binary(name) do
    case Map.get(@entries, name) do
      nil -> nil
      versions -> canonical_versions(versions)
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

  # Canonical = the keys whose value is a URL string, not an `{:alias, …}`
  # tuple. Sorted with "latest" pinned to the front and the rest
  # descending so newer pinned releases sit closer to it.
  defp canonical_versions(versions) do
    versions
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort(fn
      "latest", _ -> true
      _, "latest" -> false
      a, b -> a >= b
    end)
  end
end
