defmodule Hearth.Render.Credential do
  @moduledoc false

  # Layer 1's auth, rendered from the spec's security scheme:
  #
  #   * `:bearer`               → an `authorization: Bearer …` header
  #   * `{:api_key, :header, n}` → a request header
  #   * `{:api_key, :query, n}`  → a query parameter
  #   * `:none`                 → nothing
  #   * `{:unsupported, type}`  → nothing (Layer 1 adds a TODO comment)
  #
  # Keyed schemes attach the credential in a Req request step
  # (`put_api_key/1`), appended so it runs after Req's own `auth` and
  # `put_params` steps:
  #
  #   * the credential is looked up when each request runs, the way the
  #     entry's `credential:` says (`Hearth.Spec.Values`, via
  #     `Hearth.Render.Values`): the `:api_key` option, else
  #     `config … api_key:` by default; an option only; or a resolver,
  #     after the `:api_key` option. Its option is registered, so it is
  #     accepted by `new/1`, `request/2` and — through their `opts` —
  #     Layers 2 and 3;
  #   * a credential the caller set explicitly (`auth:`, the header, or
  #     the query param) is left alone;
  #   * the query key goes straight into the URL, never through
  #     `:params`, so it cannot collide with the caller's params.

  alias Hearth.Render.Values
  alias Hearth.Spec.Auth

  # `put_api_key/1` and `credential/1`; nothing for unkeyed schemes.
  @spec step(Auth.strategy(), Hearth.Spec.Values.t()) :: String.t()
  def step(auth, credential) do
    if Auth.keyed?(auth) do
      override = if match?({:resolve, _, _}, credential), do: :api_key

      auth_step(auth) <>
        """

        defp credential(request) do
          #{Values.lookup(credential, var: "key", override: override)}
        end
        """
    else
      ""
    end
  end

  defp auth_step(:bearer) do
    put_api_key("""
    if Req.Request.get_header(request, "authorization") == [],
      do: Req.Request.put_header(request, "authorization", "Bearer " <> credential(request)),
      else: request
    """)
  end

  defp auth_step({:api_key, :header, name}) do
    header = inspect(String.downcase(name))

    put_api_key("""
    if Req.Request.get_header(request, #{header}) == [],
      do: Req.Request.put_header(request, #{header}, credential(request)),
      else: request
    """)
  end

  defp auth_step({:api_key, :query, name}) do
    put_api_key("""
    query = request.url.query || ""

    if Map.has_key?(URI.decode_query(query), #{inspect(name)}) do
      request
    else
      param = URI.encode_query([{#{inspect(name)}, credential(request)}])
      put_in(request.url.query, Enum.join(Enum.reject([query, param], &(&1 == "")), "&"))
    end
    """)
  end

  defp put_api_key(body) do
    """

    # Runs after Req's own steps, so an explicitly set credential wins.
    defp put_api_key(request) do
      #{body}
    end\
    """
  end

  # The moduledoc section, indented to sit inside the heredoc.
  @spec doc(module(), atom(), Auth.strategy(), Hearth.Spec.Values.t()) :: String.t()
  def doc(module, otp_app, auth, credential) do
    if Auth.keyed?(auth) do
      """


      ## Credentials

      #{source(credential, module, otp_app)}
      A credential you set explicitly on the request (`auth:`, the
      header, or the query param) is left alone.
      """
      |> String.trim_trailing()
      |> String.replace(~r/^(?=.)/m, "  ")
    else
      ""
    end
  end

  defp source({:config, key}, module, otp_app) do
    """
    The credential comes from the `#{inspect(key)}` option — accepted by
    `new/1`, `request/2` and every function of the behaviour — or else
    from `config #{inspect(otp_app)}, #{inspect(module)}, #{key}: …`.
    It may be a string, a 0-arity function, or an
    `{module, function, args}` tuple, resolved when each request runs.\
    """
  end

  defp source({:option, key}, _module, _otp_app) do
    """
    The credential comes from the `#{inspect(key)}` option — accepted by
    `new/1`, `request/2` and every function of the behaviour — and is
    never read from config. It may be a string, a 0-arity function, or
    an `{module, function, args}` tuple, resolved when each request runs.\
    """
  end

  defp source({:resolve, _mf, _keys} = credential, _module, _otp_app) do
    """
    The credential comes from the `:api_key` option — accepted by
    `new/1`, `request/2` and every function of the behaviour — or else
    from #{Values.source(credential)}, called when each
    request runs. It is never read from config.\
    """
  end
end
