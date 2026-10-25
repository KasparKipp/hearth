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
  # One strategy per integration. The primary scheme is the first one the
  # top-level `security` requirement names, else the first by name.
  #
  # Choosing among several schemes: `schemes/1` lists them, `default/1`
  # is the first one Hearth can wire, and `select/2` makes one the
  # spec's only `security` requirement — so `strategy/1` picks it, here
  # and from the pruned spec. The integration's `.hearth.exs` `auth:`
  # (`describe/2`) records the choice and the alternatives.
  #
  # One scheme per integration: a requirement that names several
  # schemes at once (sent together) needs more than Layer 1's single
  # credential.

  @type strategy ::
          :none
          | :bearer
          | {:api_key, :header | :query, String.t()}
          | {:unsupported, String.t()}

  @spec strategy(map()) :: strategy()
  def strategy(spec) when is_map(spec) do
    case primary(spec) do
      nil -> :none
      name -> classify(get_in(spec, ["components", "securitySchemes", name]))
    end
  end

  # The spec's schemes with their strategies: the ones the top-level
  # `security` names, in that order, then the rest by name.
  @spec schemes(map()) :: [{String.t(), strategy()}]
  def schemes(spec) do
    schemes = get_in(spec, ["components", "securitySchemes"]) || %{}

    named =
      spec
      |> Map.get("security", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        requirement when is_map(requirement) -> Map.keys(requirement)
        _ -> []
      end)
      |> Enum.filter(&is_map(schemes[&1]))
      |> Enum.uniq()

    rest = schemes |> Map.keys() |> Enum.sort() |> Enum.reject(&(&1 in named))

    Enum.map(named ++ rest, &{&1, classify(schemes[&1])})
  end

  # The first scheme Hearth can wire, else the first there is.
  @spec default(map()) :: String.t() | nil
  def default(spec) do
    schemes = schemes(spec)

    case Enum.find(schemes, &supported?(elem(&1, 1))) || List.first(schemes) do
      {name, _strategy} -> name
      nil -> nil
    end
  end

  @spec select(map(), String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def select(spec, name) do
    schemes = schemes(spec)

    if List.keymember?(schemes, name, 0),
      do: {:ok, Map.put(spec, "security", [%{name => []}])},
      else: {:error, Enum.map(schemes, &elem(&1, 0))}
  end

  # The name of the scheme `strategy/1` wires: the first the top-level
  # `security` names, else the first by name.
  @spec primary(map()) :: String.t() | nil
  def primary(spec) do
    schemes = get_in(spec, ["components", "securitySchemes"]) || %{}
    named = spec |> Map.get("security", []) |> first_named_scheme()

    cond do
      map_size(schemes) == 0 -> nil
      is_binary(named) and is_map(schemes[named]) -> named
      true -> schemes |> Map.keys() |> Enum.sort() |> hd()
    end
  end

  # `auth: [scheme: …, available: […]]` for the integration's `.hearth.exs`
  # entry; empty when the spec has no schemes.
  @spec describe(map(), String.t() | nil) :: keyword()
  def describe(spec, scheme) do
    case schemes(spec) do
      [] ->
        []

      schemes ->
        [
          scheme: scheme,
          available: Enum.map(schemes, fn {name, s} -> {String.to_atom(name), label(s)} end)
        ]
    end
  end

  # Applies an integration's choice — its entry's `auth: [scheme: …]`, or
  # `default/1` without one — and returns the spec with that scheme
  # selected plus the entry's `auth:` record.
  @spec choose(map(), keyword()) ::
          {:ok, map(), keyword()} | {:error, {:bad_auth, term(), [String.t()]}}
  def choose(spec, entry) do
    case auth_scheme(entry) do
      {:ok, nil} ->
        case default(spec) do
          nil -> {:ok, spec, []}
          name -> chosen(spec, name)
        end

      {:ok, name} ->
        chosen(spec, name)

      {:error, value} ->
        {:error, {:bad_auth, value, Enum.map(schemes(spec), &elem(&1, 0))}}
    end
  end

  defp chosen(spec, name) do
    case select(spec, name) do
      {:ok, selected} -> {:ok, selected, describe(spec, name)}
      {:error, available} -> {:error, {:bad_auth, name, available}}
    end
  end

  # The entry's `auth: [scheme: …]`, if it names one.
  @spec auth_scheme(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def auth_scheme(entry) do
    case Keyword.get(entry, :auth) do
      nil -> {:ok, nil}
      auth when is_list(auth) -> scheme_value(Keyword.get(auth, :scheme))
      other -> {:error, other}
    end
  end

  defp scheme_value(scheme) when is_binary(scheme) or is_nil(scheme), do: {:ok, scheme}
  defp scheme_value(scheme), do: {:error, scheme}

  @spec label(strategy()) :: String.t()
  def label(:none), do: "none"
  def label(:bearer), do: "bearer"
  def label({:api_key, location, name}), do: "API key in #{location} #{name}"
  def label({:unsupported, type}), do: "#{type} (not supported)"

  defp supported?({:unsupported, _type}), do: false
  defp supported?(_strategy), do: true

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
