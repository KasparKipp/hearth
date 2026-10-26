defmodule Hearth.Render.HeadersRuntimeTest do
  use ExUnit.Case, async: true

  # Compiles real generated Layer 1 clients with `headers:` and drives
  # them through a `Req.Test` plug.

  alias Hearth.Render.Layer1

  @headers [{"x-app-key", :app_key}, {"x-tenant-id", :tenant_id}]

  def token, do: "from-mfa"

  defp client(auth, config) do
    n = System.unique_integer([:positive])
    module = Module.concat([__MODULE__, "Client#{n}"])
    otp_app = :"hearth_headers_runtime_#{n}"

    module
    |> Layer1.render(otp_app, "https://api.example.com", "", auth, headers: @headers)
    |> Code.compile_string()

    Application.put_env(otp_app, module, config)
    on_exit(fn -> Application.delete_env(otp_app, module) end)
    module
  end

  defp call(client, opts \\ []) do
    test = self()

    plug = fn conn ->
      send(test, {:conn, conn})
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert %Req.Response{status: 200} = client.request!("/ping", [plug: plug] ++ opts)
    assert_received {:conn, conn}
    conn
  end

  defp header(conn, name), do: Plug.Conn.get_req_header(conn, name)

  test "sends each header from config — a string, a fun or an MFA" do
    conn =
      :none
      |> client(app_key: "key-1", tenant_id: fn -> "tenant-1" end)
      |> call()

    assert header(conn, "x-app-key") == ["key-1"]
    assert header(conn, "x-tenant-id") == ["tenant-1"]

    mfa = client(:none, app_key: {__MODULE__, :token, []}, tenant_id: "H")
    assert mfa |> call() |> header("x-app-key") == ["from-mfa"]
  end

  test "a per-call option overrides config" do
    conn = :none |> client(app_key: "key-1", tenant_id: "tenant-1") |> call(tenant_id: "tenant-2")

    assert header(conn, "x-tenant-id") == ["tenant-2"]
  end

  test "a header set on the request wins" do
    conn =
      :none
      |> client(app_key: "key-1", tenant_id: "tenant-1")
      |> call(headers: [{"x-tenant-id", "MINE"}])

    assert header(conn, "x-tenant-id") == ["MINE"]
  end

  test "a missing value raises when the request runs, naming the header" do
    client = client(:none, app_key: "key-1")

    assert %Req.Request{} = client.new()

    assert_raise RuntimeError, ~r/missing :tenant_id .* x-tenant-id header/, fn ->
      call(client)
    end
  end

  test "works alongside a wired credential" do
    conn = :bearer |> client(api_key: "secret", app_key: "key-1", tenant_id: "H") |> call()

    assert header(conn, "authorization") == ["Bearer secret"]
    assert header(conn, "x-app-key") == ["key-1"]
  end
end
