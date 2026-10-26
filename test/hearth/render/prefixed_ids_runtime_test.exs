defmodule Hearth.Render.PrefixedIdsRuntimeTest do
  use ExUnit.Case, async: true

  # Compiles real generated Layer 1/2/3 modules with `prefixed_ids:` and
  # drives them through a `Req.Test` plug: the functions must reach the
  # right path with the right method.

  alias Hearth.Render.{Layer1, Layer2, Layer3, ModuleNames}

  @prefixed %{
    functions: [retrieve: :get, update: :post, delete: :delete],
    resources: [
      %{prefix: "cus", path: "/v1/customers/{customer}", methods: [:get, :post, :delete]},
      %{prefix: "sub", path: "/v1/subscriptions/{id}", methods: [:get, :post]}
    ],
    base_path: "/v1"
  }

  defp compile do
    n = System.unique_integer([:positive])
    names = ModuleNames.from_layer1(Module.concat([__MODULE__, "Shop#{n}"]))

    Layer1.render(
      names.layer1,
      :hearth_prefixed_test,
      "https://api.shop.test",
      "/v1",
      :none,
      @prefixed
    )
    |> Code.compile_string()

    Layer2.render(names.layer2, [], otp_app: :hearth_prefixed_test, prefixed: @prefixed)
    |> Code.compile_string()

    Layer3.render(names.layer3, names.layer2, names.layer1, [], @prefixed)
    |> Code.compile_string()

    names
  end

  # Calls `function` on Layer 3 and returns `{method, path}` the plug saw.
  defp call(names, function, id) do
    test = self()

    plug = fn conn ->
      send(test, {:request, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    result = apply(names.layer3, function, [id, [plug: plug]])

    receive do
      {:request, method, path} -> {result, method, path}
    after
      0 -> result
    end
  end

  test "each function sends its method to the id's resource path" do
    names = compile()

    assert {{:ok, %Req.Response{status: 200}}, "GET", "/v1/customers/cus_123"} =
             call(names, :retrieve, "cus_123")

    assert {{:ok, _}, "POST", "/v1/subscriptions/sub_9"} = call(names, :update, "sub_9")
    assert {{:ok, _}, "DELETE", "/v1/customers/cus_1"} = call(names, :delete, "cus_1")
  end

  test "Layer 1's request/2 takes a prefixed id as its resource's path" do
    names = compile()
    test = self()

    plug = fn conn ->
      send(test, {:request, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    assert {:ok, _} = names.layer1.request("cus_1", plug: plug)
    assert_received {:request, "GET", "/v1/customers/cus_1"}

    assert {:ok, _} =
             names.layer1.request("cus_1/balance_transactions", method: :post, plug: plug)

    assert_received {:request, "POST", "/v1/customers/cus_1/balance_transactions"}

    assert {:ok, _} = names.layer1.request("/plain/path", plug: plug)
    assert_received {:request, "GET", "/v1/plain/path"}
  end

  test "an unknown prefix goes through as a plain path" do
    names = compile()

    assert {{:ok, _}, "GET", "/v1/xx_1"} = call(names, :retrieve, "xx_1")
  end

  test "Layer 2 declares the callbacks" do
    names = compile()

    callbacks = names.layer2.behaviour_info(:callbacks)
    assert {:retrieve, 2} in callbacks
    assert {:update, 2} in callbacks
    assert {:delete, 2} in callbacks
  end
end
