defmodule Hearth.Spec.Fetcher do
  @moduledoc false

  # Downloads a spec over HTTP(S) with OTP's `:httpc` — no dependency, so
  # it works on the first `mix hearth.gen`, before the host project has
  # Req. HTTPS certificates are verified against the OS trust store;
  # redirects are followed. No caching: callers fetch when they need the
  # spec, and `source_sha256` records what they got.

  @timeout 30_000

  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    request = {String.to_charlist(url), [{~c"user-agent", ~c"hearth"}]}
    http_options = [timeout: @timeout, connect_timeout: @timeout, autoredirect: true, ssl: ssl()]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 -> {:ok, body}
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec describe_error(term()) :: String.t()
  def describe_error({:status, status}), do: "the server answered HTTP #{status}"

  def describe_error({:failed_connect, details}) do
    case List.keyfind(details, :inet, 0) do
      {:inet, _families, {:tls_alert, {_alert, message}}} -> "TLS failed: #{message}"
      {:inet, _families, reason} -> "could not connect (#{inspect(reason)})"
      nil -> "could not connect"
    end
  end

  def describe_error(:timeout), do: "the request timed out"
  def describe_error(reason), do: inspect(reason)

  defp ssl do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
