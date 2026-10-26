defmodule OhipDemo.TenancyTest do
  use ExUnit.Case, async: true

  import Mox

  alias OhipDemo.Integrations.OhipOauth.OhipOauthApi
  alias OhipDemo.Tenancy

  setup :verify_on_exit!

  # Each test gets its own chain, so cached tokens don't leak between them.
  defp chain do
    n = System.unique_integer([:positive])

    %{
      gateway: "https://gw#{n}.example.test",
      app_key: "app-#{n}",
      client_id: "client-#{n}",
      client_secret: "secret-#{n}",
      enterprise_id: "ENT#{n}",
      scope: "urn:opc:hgbu:ws:__myscopes__"
    }
  end

  defp token_response(token, expires_in) do
    {:ok,
     %Req.Response{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}}
  end

  test "the chain's values" do
    chain = chain()

    assert Tenancy.gateway(chain: chain) == chain.gateway
    assert Tenancy.app_key(chain: chain) == chain.app_key
    assert Tenancy.enterprise_id(chain: chain) == chain.enterprise_id
    assert Tenancy.client_credentials(chain: chain) == "#{chain.client_id}:#{chain.client_secret}"
  end

  test "a token is requested once per chain, then cached" do
    chain = chain()

    expect(OhipOauthApi.Mock, :get_token, fn opts ->
      assert opts[:form] == [grant_type: "client_credentials", scope: chain.scope]
      assert opts[:chain] == chain
      token_response("token-1", 3600)
    end)

    assert Tenancy.token(chain: chain) == "token-1"
    assert Tenancy.token(chain: chain) == "token-1"
  end

  test "chains don't share tokens" do
    expect(OhipOauthApi.Mock, :get_token, 2, fn opts ->
      token_response("token-for-" <> opts[:chain].client_id, 3600)
    end)

    [a, b] = [chain(), chain()]
    assert Tenancy.token(chain: a) == "token-for-" <> a.client_id
    assert Tenancy.token(chain: b) == "token-for-" <> b.client_id
  end

  test "a token about to expire is requested again" do
    chain = chain()

    OhipOauthApi.Mock
    |> expect(:get_token, fn _opts -> token_response("short-lived", 30) end)
    |> expect(:get_token, fn _opts -> token_response("fresh", 3600) end)

    assert Tenancy.token(chain: chain) == "short-lived"
    assert Tenancy.token(chain: chain) == "fresh"
  end

  test "a failed token request raises, naming the gateway and status" do
    chain = chain()
    expect(OhipOauthApi.Mock, :get_token, fn _opts -> {:ok, %Req.Response{status: 401}} end)

    assert_raise RuntimeError, ~r/#{chain.gateway} failed with status 401/, fn ->
      Tenancy.token(chain: chain)
    end
  end

  test "a block request carries the chain's gateway, token and app key, and the hotel id" do
    chain = chain()
    expect(OhipOauthApi.Mock, :get_token, fn _opts -> token_response("token-1", 3600) end)

    plug = fn conn ->
      assert conn.host == URI.parse(chain.gateway).host
      assert conn.request_path == "/blk/v1/hotels/HOTEL1/blocks/B42"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token-1"]
      assert Plug.Conn.get_req_header(conn, "x-app-key") == [chain.app_key]
      assert Plug.Conn.get_req_header(conn, "x-hotelid") == ["HOTEL1"]
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    assert {:ok, %Req.Response{status: 200}} =
             OhipDemo.Integrations.Ohip.OhipApi.Req.get_block("B42", "HOTEL1",
               chain: chain,
               hotel_id: "HOTEL1",
               plug: plug
             )
  end

  test "without chain:, says so" do
    assert_raise ArgumentError, ~r/`chain:`/, fn -> Tenancy.gateway([]) end
  end
end
