defmodule OhipDemo.Tenancy do
  @moduledoc """
  The per-chain OHIP values the generated clients ask for when each
  request runs (`base_url:`, `auth: [credential:]` and `headers:` in
  `.hearth.exs`).

  A hotel chain shares one gateway, app key, client ID and secret,
  enterprise ID and scope; its hotels differ only by hotel ID, which
  each call passes as `hotel_id:`. Every call passes the chain it acts
  for as `chain:`, and nothing here comes from config.

  The bearer token comes from OHIP's OAuth API (`OhipOauthApi`, generated
  by Hearth): one token per chain environment, cached until shortly
  before it expires (`OhipDemo.Tenancy.Tokens`).
  """

  alias OhipDemo.Integrations.OhipOauth.OhipOauthApi
  alias OhipDemo.Tenancy.Tokens

  @type chain :: %{
          gateway: String.t(),
          app_key: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          enterprise_id: String.t(),
          scope: String.t()
        }

  @doc "The chain's OHIP gateway URL."
  @spec gateway(keyword()) :: String.t()
  def gateway(opts), do: chain!(opts).gateway

  @doc "The chain's application key, for `x-app-key`."
  @spec app_key(keyword()) :: String.t()
  def app_key(opts), do: chain!(opts).app_key

  @doc "The chain's enterprise ID, for the token request."
  @spec enterprise_id(keyword()) :: String.t()
  def enterprise_id(opts), do: chain!(opts).enterprise_id

  @doc "The chain's `client_id:client_secret`, for the token request's basic auth."
  @spec client_credentials(keyword()) :: String.t()
  def client_credentials(opts) do
    chain = chain!(opts)
    chain.client_id <> ":" <> chain.client_secret
  end

  @doc "A bearer token for the chain: the cached one, else a new one from OHIP's OAuth API."
  @spec token(keyword()) :: String.t()
  def token(opts) do
    chain = chain!(opts)
    Tokens.fetch(chain, fn -> request_token(chain) end)
  end

  defp request_token(chain) do
    form = [grant_type: "client_credentials", scope: chain.scope]

    case OhipOauthApi.get_token(form: form, chain: chain) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}} ->
        {token, seconds(body["expires_in"])}

      {:ok, %Req.Response{status: status}} ->
        raise "OHIP token request to #{chain.gateway} failed with status #{status}"

      {:error, exception} ->
        raise exception
    end
  end

  defp seconds(seconds) when is_integer(seconds), do: seconds
  defp seconds(seconds) when is_binary(seconds), do: String.to_integer(seconds)

  defp chain!(opts) do
    opts[:chain] || raise ArgumentError, "pass the hotel chain as `chain:`"
  end
end
