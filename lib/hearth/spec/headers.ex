defmodule Hearth.Spec.Headers do
  @moduledoc false

  # An integration's `headers:` in `.hearth.exs` — request headers the
  # raw client sends on every call, each with the config key its value
  # comes from:
  #
  #     headers: ["x-app-key": :app_key, "x-tenant-id": :tenant_id]
  #
  # Layer 1 resolves each value per request, like `api_key`: the call's
  # option (`tenant_id: "…"`), else `config :app, Client, tenant_id: …`; a
  # string, a 0-arity fun or an `{m, f, a}`. A header already on the
  # request wins.
  #
  # Pure. `suggestions/3` finds the header parameters every selected
  # operation requires that nothing sends yet, for gen to point at.

  alias Hearth.Spec.Operation

  # Names Req or Layer 1 already use as request options (Req 0.7's
  # registered options plus `Req.new/1`'s own) — a per-call
  # `tenant_id: …` travels through the same keyword.
  @reserved ~w(
    api_key method url headers body into adapter options
    auth aws_sigv4 base_url cache cache_dir checksum compress_body compressed
    connect_options decode_body decode_json decoders finch finch_private finch_request
    follow_redirects form form_multipart http_errors inet6 json location_trusted
    max_redirects max_retries params path_params path_params_style plug
    pool_max_idle_time pool_timeout range raw receive_timeout redact_auth redirect
    redirect_log_level redirect_trusted request_timeout retry retry_delay
    retry_log_level unix_socket user_agent
  )a

  @spec parse(keyword()) :: {:ok, [{String.t(), atom()}]} | {:error, String.t()}
  def parse(entry) do
    headers = Keyword.get(entry, :headers, [])

    with true <- Keyword.keyword?(headers) || {:error, shape_message()},
         pairs =
           Enum.map(headers, fn {header, key} ->
             {header |> Atom.to_string() |> String.downcase(), key}
           end),
         :ok <- check(pairs) do
      {:ok, pairs}
    end
  end

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

  defp check(pairs) do
    keys = Enum.map(pairs, &elem(&1, 1))

    cond do
      not Enum.all?(pairs, fn {header, _key} ->
        Regex.match?(~r/^[a-z0-9][a-z0-9!#$%&'*+.^_`|~-]*$/, header)
      end) ->
        {:error, "`headers:` names must be HTTP header names, e.g. `\"x-app-key\": :app_key`."}

      not Enum.all?(
        keys,
        &(is_atom(&1) and Regex.match?(~r/^[a-z_][a-z0-9_]*$/, Atom.to_string(&1)))
      ) ->
        {:error, shape_message()}

      length(Enum.uniq(keys)) != length(keys) ->
        {:error, "`headers:` gives two headers the same config key."}

      (reserved = Enum.filter(keys, &(&1 in @reserved))) != [] ->
        {:error,
         "`headers:` config key #{Enum.map_join(reserved, ", ", &inspect/1)} is already a request option; pick another."}

      true ->
        :ok
    end
  end

  defp shape_message do
    "`headers:` maps header names to the config keys their values come from, " <>
      ~s|e.g. `headers: ["x-app-key": :app_key, "x-tenant-id": :tenant_id]`.|
  end
end
