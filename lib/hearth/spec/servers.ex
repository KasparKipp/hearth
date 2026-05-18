defmodule Hearth.Spec.Servers do
  @moduledoc false

  # Resolves a spec's `servers:` list into a default base URL and a
  # test base URL.
  #
  # A server URL is "non-prod" when it contains a dev/staging/preview/
  # demo/sandbox marker, or its host TLD is `.dev`. Otherwise it is a
  # prod-candidate.
  #
  #   * the **default** URL — Layer 1's `@base_url` — is a prod
  #     candidate (or, with several, the first; the rest are surfaced
  #     as commented-out config overrides);
  #   * the **test** URL — written into `config/test.exs`, where the
  #     generated external test points — is a non-prod server.
  #
  # Pure: no I/O. The gen task drives the rendering and config patches.

  @non_prod_markers ["dev.", "staging.", "preview.", "demo.", "sandbox."]

  @type t :: %{
          default: String.t() | nil,
          default_alternates: [String.t()],
          test: String.t() | nil,
          test_alternates: [String.t()],
          warn?: boolean(),
          fallback_default?: boolean()
        }

  @doc "The `servers[].url` strings from a decoded spec, in spec order."
  @spec urls(map()) :: [String.t()]
  def urls(spec) do
    spec
    |> Map.get("servers", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"url" => url} -> url
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end

  @doc "True when a URL looks like a non-production server."
  @spec non_prod?(String.t()) :: boolean()
  def non_prod?(url) when is_binary(url) do
    Enum.any?(@non_prod_markers, &String.contains?(url, &1)) or dev_tld?(url)
  end

  @doc "Resolves the spec's `servers:` list — see the module comment."
  @spec resolve(map()) :: t()
  def resolve(spec), do: spec |> urls() |> from_urls()

  defp from_urls([]) do
    %{
      default: nil,
      default_alternates: [],
      test: nil,
      test_alternates: [],
      warn?: true,
      fallback_default?: false
    }
  end

  defp from_urls([only]) do
    %{blank() | default: only, test: only}
  end

  defp from_urls(urls) do
    {non_prod, prod} = Enum.split_with(urls, &non_prod?/1)
    {default, default_alternates, fallback?} = pick_default(prod, urls)
    {test, test_alternates} = pick_test(non_prod, urls)

    %{
      blank()
      | default: default,
        default_alternates: default_alternates,
        test: test,
        test_alternates: test_alternates,
        fallback_default?: fallback?
    }
  end

  # prod-candidates → {default URL, alternates to document, fallback?}.
  defp pick_default([single], _urls), do: {single, [], false}
  defp pick_default([], urls), do: {hd(urls), [], true}
  defp pick_default(prod, _urls), do: {hd(prod), prod, false}

  # non-prod servers → {test URL, alternates to document}.
  defp pick_test([], urls), do: {hd(urls), []}
  defp pick_test([single], _urls), do: {single, []}
  defp pick_test(non_prod, _urls), do: {hd(non_prod), non_prod}

  defp blank do
    %{
      default: nil,
      default_alternates: [],
      test: nil,
      test_alternates: [],
      warn?: false,
      fallback_default?: false
    }
  end

  defp dev_tld?(url) do
    case URI.parse(url).host do
      host when is_binary(host) -> host |> String.split(".") |> List.last() == "dev"
      _ -> false
    end
  end
end
