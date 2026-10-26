defmodule Hearth.Spec.Headers do
  @moduledoc false

  # An integration's `headers:` in `.hearth.exs` — request headers the
  # raw client sends on every call. `Hearth.Spec.Values` parses them,
  # with where each value comes from.
  #
  # Pure. `suggestions/3` finds the header parameters every selected
  # operation requires that nothing sends yet, for gen to point at.

  alias Hearth.Spec.Operation

  @spec suggestions([Operation.t()], [{String.t(), atom()}], term()) :: [{String.t(), atom()}]
  def suggestions([], _headers, _auth), do: []

  def suggestions(operations, headers, auth) do
    covered = MapSet.new(Enum.map(headers, &elem(&1, 0)) ++ auth_headers(auth))

    operations
    |> Enum.map(&required_headers/1)
    |> Enum.reduce(&intersection/2)
    |> Enum.reject(&MapSet.member?(covered, &1))
    |> Enum.map(&{&1, config_key(&1)})
  end

  defp required_headers(%Operation{header_params: params}) do
    for %{"name" => name} = param <- List.wrap(params),
        param["required"] == true,
        do: String.downcase(name)
  end

  # Keeps the first list's order.
  defp intersection(next, acc), do: Enum.filter(acc, &(&1 in next))

  defp auth_headers(:bearer), do: ["authorization"]
  defp auth_headers({:api_key, :header, name}), do: [String.downcase(name)]
  defp auth_headers(_auth), do: []

  # `x-tenant-id` → `:tenant_id`, `Accept-Language` → `:accept_language`.
  defp config_key(header) do
    header
    |> String.replace_prefix("x-", "")
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end
end
