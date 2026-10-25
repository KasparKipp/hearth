defmodule Hearth.Spec.BasePathTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.BasePath
  alias Hearth.Spec.Operation

  defp ops(paths), do: Enum.map(paths, &struct(Operation, path: &1))

  describe "common_prefix/1" do
    test "finds the longest leading segment sequence shared by all paths" do
      assert BasePath.common_prefix(ops(["/api/v1/customers", "/api/v1/subscriptions"])) ==
               "/api/v1"
    end

    test "stops at the first differing segment" do
      assert BasePath.common_prefix(ops(["/api/v1/x", "/api/v2/y"])) == "/api"
    end

    test ~s(returns "" when paths share no leading segment) do
      assert BasePath.common_prefix(ops(["/customers", "/orders"])) == ""
    end

    test "never consumes a whole path — every operation keeps a segment" do
      # The three paths share [api, v1, customers], but the shortest is
      # itself 3 segments, so the prefix caps one short at /api/v1.
      assert BasePath.common_prefix(ops(["/api/v1/customers", "/api/v1/customers/{id}"])) ==
               "/api/v1"
    end

    test ~s(returns "" when the shortest path is a single segment) do
      assert BasePath.common_prefix(ops(["/pets", "/pets/{id}"])) == ""
    end

    test ~s(returns "" for an empty operation list) do
      assert BasePath.common_prefix([]) == ""
    end

    test "stops before a templated segment — a path param never folds into the base URL" do
      paths = [
        "/v1/accounts/{account_id}/charges",
        "/v1/accounts/{account_id}/payouts"
      ]

      assert BasePath.common_prefix(ops(paths)) == "/v1/accounts"
    end

    test ~s(returns "" when the first shared segment is templated) do
      assert BasePath.common_prefix(ops(["/{tenant}/users", "/{tenant}/orders"])) == ""
    end

    test "treats a segment with an embedded template as templated" do
      # `{file}.json` still carries a path param.
      paths = ["/v1/files/{file}.json/meta", "/v1/files/{file}.json/data"]

      assert BasePath.common_prefix(ops(paths)) == "/v1/files"
    end
  end

  describe "strip/2" do
    test "drops the prefix from every operation path" do
      stripped = BasePath.strip(ops(["/api/v1/customers", "/api/v1/orders/{id}"]), "/api/v1")
      assert Enum.map(stripped, & &1.path) == ["/customers", "/orders/{id}"]
    end

    test ~s(a "" prefix leaves operations untouched) do
      operations = ops(["/customers"])
      assert BasePath.strip(operations, "") == operations
    end
  end
end
