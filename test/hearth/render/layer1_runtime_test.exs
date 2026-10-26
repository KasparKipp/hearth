defmodule Hearth.Render.Layer1RuntimeTest do
  use ExUnit.Case, async: true

  # Compiles real generated Layer 1 clients and drives them through a
  # `Req.Test` plug — the renderer's string assertions can't tell whether
  # auth survives Req's option merging at runtime.

  alias Hearth.Render.Layer1

  @header {:api_key, :header, "X-API-Key"}
  @query {:api_key, :query, "api_key"}

  def token(value), do: "mfa-" <> value

  # A freshly compiled client with its own module and otp_app, so tests
  # can set config independently and stay async.
  defp client(auth, api_key \\ nil) do
    n = System.unique_integer([:positive])
    module = Module.concat([__MODULE__, "Client#{n}"])
    otp_app = :"hearth_layer1_runtime_#{n}"

    module
    |> Layer1.render(otp_app, "https://api.example.com", "", auth)
    |> Code.compile_string()

    if api_key, do: Application.put_env(otp_app, module, api_key: api_key)
    on_exit(fn -> Application.delete_env(otp_app, module) end)

    module
  end

  # Performs `client.request!/2` against a plug and returns the conn it saw.
  defp call(client, opts \\ []) do
    test = self()

    plug = fn conn ->
      send(test, {:conn, Plug.Conn.fetch_query_params(conn)})
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert %Req.Response{status: 200} = client.request!("/ping", [plug: plug] ++ opts)
    assert_received {:conn, conn}
    conn
  end

  defp header(conn, name), do: Plug.Conn.get_req_header(conn, name)

  describe "basic" do
    test "sends the configured user:password, base64-encoded" do
      conn = :basic |> client("id:secret") |> call()
      assert header(conn, "authorization") == ["Basic " <> Base.encode64("id:secret")]
    end

    test "a per-call api_key: overrides config" do
      conn = :basic |> client("id:secret") |> call(api_key: "other:pw")
      assert header(conn, "authorization") == ["Basic " <> Base.encode64("other:pw")]
    end

    test "the caller's explicit auth: wins" do
      conn = :basic |> client("id:secret") |> call(auth: {:basic, "mine:pw"})
      assert header(conn, "authorization") == ["Basic " <> Base.encode64("mine:pw")]
    end
  end

  describe "bearer" do
    test "sends the configured credential" do
      conn = :bearer |> client("cfg") |> call()
      assert header(conn, "authorization") == ["Bearer cfg"]
    end

    test "a per-call api_key: overrides config" do
      conn = :bearer |> client("cfg") |> call(api_key: "call")
      assert header(conn, "authorization") == ["Bearer call"]
    end

    test "the caller's explicit auth: wins" do
      conn = :bearer |> client("cfg") |> call(auth: {:bearer, "mine"})
      assert header(conn, "authorization") == ["Bearer mine"]
    end
  end

  describe "API key in a header" do
    test "sends the configured credential" do
      conn = @header |> client("cfg") |> call()
      assert header(conn, "x-api-key") == ["cfg"]
    end

    test "a per-call api_key: overrides config" do
      conn = @header |> client("cfg") |> call(api_key: "call")
      assert header(conn, "x-api-key") == ["call"]
    end

    test "the caller's own header wins" do
      conn = @header |> client("cfg") |> call(headers: [{"x-api-key", "mine"}])
      assert header(conn, "x-api-key") == ["mine"]
    end
  end

  describe "API key in the query" do
    test "sends the configured credential" do
      conn = @query |> client("cfg") |> call()
      assert conn.query_params == %{"api_key" => "cfg"}
    end

    test "survives the caller's params:" do
      conn = @query |> client("cfg") |> call(params: [limit: 5])
      assert conn.query_params == %{"api_key" => "cfg", "limit" => "5"}
    end

    test "a per-call api_key: overrides config" do
      conn = @query |> client("cfg") |> call(api_key: "call", params: [limit: 5])
      assert conn.query_params == %{"api_key" => "call", "limit" => "5"}
    end

    test "the caller's own param of the same name wins" do
      conn = @query |> client("cfg") |> call(params: [api_key: "mine"])
      assert conn.query_params == %{"api_key" => "mine"}
    end
  end

  describe "credential sources" do
    test "a 0-arity fun in config" do
      conn = @header |> client(fn -> "from-fun" end) |> call()
      assert header(conn, "x-api-key") == ["from-fun"]
    end

    test "an MFA in config" do
      conn = @header |> client({__MODULE__, :token, ["cfg"]}) |> call()
      assert header(conn, "x-api-key") == ["mfa-cfg"]
    end

    test "a fun or an MFA per call" do
      client = client(@header, "cfg")
      assert client |> call(api_key: fn -> "f" end) |> header("x-api-key") == ["f"]

      assert client |> call(api_key: {__MODULE__, :token, ["c"]}) |> header("x-api-key") == [
               "mfa-c"
             ]
    end

    test "is resolved on every request, not when the request is built" do
      test = self()

      client =
        client(@header, fn ->
          send(test, :resolved)
          "k"
        end)

      call(client)
      call(client)

      assert_received :resolved
      assert_received :resolved
    end

    test "new/1 accepts api_key: too" do
      test = self()

      plug = fn conn ->
        send(test, {:key, Plug.Conn.get_req_header(conn, "x-api-key")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      client = client(@header)
      Req.request!(client.new(api_key: "built", url: "/ping", plug: plug))

      assert_received {:key, ["built"]}
    end
  end

  describe "a missing credential" do
    test "raises when the request runs, not when it is built" do
      client = client(@header)

      assert %Req.Request{} = client.new()
      assert_raise RuntimeError, ~r/missing :api_key for/, fn -> call(client) end
    end
  end
end
