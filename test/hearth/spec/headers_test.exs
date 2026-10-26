defmodule Hearth.Spec.HeadersTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Headers
  alias Hearth.Spec.Operation

  describe "suggestions/3" do
    defp operations(header_params_per_op) do
      paths =
        header_params_per_op
        |> Enum.with_index()
        |> Map.new(fn {params, i} ->
          {"/r#{i}", %{"get" => %{"operationId" => "op#{i}", "parameters" => params}}}
        end)

      Operation.extract(%{"paths" => paths})
    end

    @app_key %{"name" => "x-app-key", "in" => "header", "required" => true}
    @tenant %{"name" => "X-Tenant-Id", "in" => "header", "required" => true}
    @request_id %{"name" => "x-request-id", "in" => "header"}

    test "header params every operation requires, with a derived config key" do
      ops = operations([[@app_key, @tenant, @request_id], [@app_key, @tenant]])

      assert Headers.suggestions(ops, [], :none) ==
               [{"x-app-key", :app_key}, {"x-tenant-id", :tenant_id}]
    end

    test "leaves out headers that only some operations require" do
      ops = operations([[@app_key, @tenant], [@app_key]])

      assert Headers.suggestions(ops, [], :none) == [{"x-app-key", :app_key}]
    end

    test "leaves out headers already covered by headers: or by the auth scheme" do
      ops = operations([[@app_key, @tenant]])

      assert Headers.suggestions(ops, [{"x-tenant-id", :tenant_id}], :none) == [
               {"x-app-key", :app_key}
             ]

      assert Headers.suggestions(ops, [], {:api_key, :header, "X-App-Key"}) == [
               {"x-tenant-id", :tenant_id}
             ]

      auth = operations([[%{"name" => "Authorization", "in" => "header", "required" => true}]])
      assert Headers.suggestions(auth, [], :bearer) == []
    end

    test "no operations, no suggestions" do
      assert Headers.suggestions([], [], :none) == []
    end
  end
end
