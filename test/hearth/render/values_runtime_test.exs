defmodule Hearth.Render.ValuesRuntimeTest do
  use ExUnit.Case, async: true

  # Compiles real generated Layer 1 clients whose credential and base URL
  # come from a per-call option or a resolver, and drives them through a
  # `Req.Test` plug.

  alias Hearth.Render.Layer1
  alias Hearth.Spec.Values

  def token(opts) do
    send(self(), {:resolver_opts, opts})
    if opts[:tenant] == "nobody", do: nil, else: "token-for-" <> (opts[:tenant] || "none")
  end

  def gateway(opts), do: "https://#{opts[:region] || "eu"}.gateway.test"

  defp client(auth, values, config \\ [], base \\ {"https://api.example.com", ""}) do
    n = System.unique_integer([:positive])
    module = Module.concat([__MODULE__, "Client#{n}"])
    otp_app = :"hearth_values_runtime_#{n}"
    {base_url, path_prefix} = base
    source = Layer1.render(module, otp_app, base_url, path_prefix, auth, values: values)
    Code.compile_string(source)

    Application.put_env(otp_app, module, config)
    on_exit(fn -> Application.delete_env(otp_app, module) end)
    {module, source}
  end

  defp values(fields), do: Map.merge(Values.default(), Map.new(fields))

  defp call(client, opts) do
    test = self()

    plug = fn conn ->
      send(test, {:conn, conn})
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert %Req.Response{status: 200} = client.request!("/ping", [plug: plug] ++ opts)
    assert_received {:conn, conn}
    conn
  end

  defp bearer(conn), do: Plug.Conn.get_req_header(conn, "authorization")

  # The config keys the generated code reads.
  defp config_reads(source) do
    ~r/Application\.get_env\(@otp_app, __MODULE__, \[\]\)\[(:\w+)\]/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
  end

  describe "credential: [option:]" do
    setup do
      {client, source} =
        client(:bearer, values(credential: {:option, :token}), token: "from-config")

      %{client: client, source: source}
    end

    test "comes from the option, never from config", %{client: client, source: source} do
      assert client |> call(token: "per-call") |> bearer() == ["Bearer per-call"]
      assert client |> call(token: fn -> "fun" end) |> bearer() == ["Bearer fun"]
      assert config_reads(source) == [":base_url"]

      assert_raise RuntimeError, ~r/missing :token/, fn -> call(client, []) end
    end
  end

  describe "credential: [resolve:]" do
    setup do
      credential = {:resolve, {__MODULE__, :token}, [:tenant]}
      {client, source} = client(:bearer, values(credential: credential), api_key: "from-config")
      %{client: client, source: source}
    end

    test "the resolver gets the listed options only", %{client: client} do
      assert client |> call(tenant: "acme") |> bearer() == ["Bearer token-for-acme"]
      assert_received {:resolver_opts, [tenant: "acme"]}
    end

    test "an api_key: option wins; config is never read", %{client: client, source: source} do
      assert client |> call(api_key: "per-call", tenant: "acme") |> bearer() == [
               "Bearer per-call"
             ]

      refute_received {:resolver_opts, _}
      assert config_reads(source) == [":base_url"]
    end

    test "a resolver returning no string raises without showing it", %{client: client} do
      error = assert_raise RuntimeError, fn -> call(client, tenant: "nobody") end
      assert error.message =~ "#{inspect(__MODULE__)}.token/1"
      refute error.message =~ "nil"
    end
  end

  describe "base_url:" do
    test "[resolve:] sets the base URL per request; a base_url: option wins" do
      from = {:resolve, {__MODULE__, :gateway}, [:region]}
      {client, source} = client(:none, values(base_url: from))

      assert call(client, region: "us").host == "us.gateway.test"
      assert call(client, base_url: "https://mine.test").host == "mine.test"
      refute source =~ "@base_url"
      refute source =~ "Application.get_env"
    end

    test "[resolve:] gives the host; the spec's base path is appended, a base_url: option is as is" do
      from = {:resolve, {__MODULE__, :gateway}, [:region]}
      # A spec with a relative server (`/oauth/v1`) and no host.
      {client, _source} = client(:none, values(base_url: from), [], {nil, "/oauth/v1"})

      conn = call(client, region: "us")
      assert {conn.host, conn.request_path} == {"us.gateway.test", "/oauth/v1/ping"}

      conn = call(client, base_url: "https://mine.test/v9")
      assert {conn.host, conn.request_path} == {"mine.test", "/v9/ping"}
    end

    test "[option:] raises without base_url:" do
      {client, _source} = client(:none, values(base_url: {:option, :base_url}))

      assert call(client, base_url: "https://mine.test").host == "mine.test"
      assert_raise RuntimeError, ~r/missing :base_url/, fn -> call(client, []) end
    end

    test ":base_url keeps reading config, else the spec's" do
      {client, _source} =
        client(:none, values(base_url: {:config, :base_url}), base_url: "https://cfg.test")

      assert call(client, []).host == "cfg.test"
    end
  end
end
