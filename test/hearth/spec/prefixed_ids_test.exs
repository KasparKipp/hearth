defmodule Hearth.Spec.PrefixedIdsTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Operation
  alias Hearth.Spec.PrefixedIds

  @spec_map %{
    "paths" => %{
      "/v1/customers" => %{"get" => %{"operationId" => "GetCustomers"}},
      "/v1/customers/{customer}" => %{
        "get" => %{"operationId" => "GetCustomersCustomer"},
        "post" => %{"operationId" => "PostCustomersCustomer"},
        "delete" => %{"operationId" => "DeleteCustomersCustomer"}
      },
      "/v1/subscriptions/{subscription_exposed_id}" => %{
        "get" => %{"operationId" => "GetSubscriptionsSubscriptionExposedId"},
        "post" => %{"operationId" => "PostSubscriptionsSubscriptionExposedId"}
      },
      "/v1/customers/{customer}/sources/{id}" => %{"get" => %{"operationId" => "GetSource"}}
    }
  }

  defp parse!(prefixed_ids) do
    {:ok, parsed} = PrefixedIds.parse(prefixed_ids: prefixed_ids)
    parsed
  end

  describe "parse/1" do
    test "reads functions and prefixes" do
      assert PrefixedIds.parse(
               prefixed_ids: [
                 functions: [retrieve: :get, update: :post],
                 prefixes: [cus: "GetCustomersCustomer", sub: "/v1/subscriptions/{id}"]
               ]
             ) ==
               {:ok,
                %{
                  functions: [retrieve: :get, update: :post],
                  prefixes: [{"cus", "GetCustomersCustomer"}, {"sub", "/v1/subscriptions/{id}"}]
                }}
    end

    test "functions default to retrieve: :get" do
      assert {:ok, %{functions: [retrieve: :get]}} =
               PrefixedIds.parse(prefixed_ids: [prefixes: [cus: "GetCustomersCustomer"]])
    end

    test "an entry without prefixed_ids has none" do
      assert PrefixedIds.parse(module: X) == {:ok, nil}
    end

    test "rejects malformed values" do
      for bad <- [
            :nope,
            [prefixes: [cus: :GetCustomersCustomer]],
            [prefixes: []],
            [functions: [retrieve: :fetch], prefixes: [cus: "X"]],
            [functions: [{:"Not Valid", :get}], prefixes: [cus: "X"]],
            [functions: [], prefixes: [cus: "X"]],
            [other: 1, prefixes: [cus: "X"]]
          ] do
        assert {:error, message} = PrefixedIds.parse(prefixed_ids: bad), inspect(bad)
        assert message =~ "prefixed_ids:"
      end
    end
  end

  describe "resolve/2" do
    test "an operationId names its resource's path, with the methods the spec has there" do
      parsed = parse!(prefixes: [cus: "GetCustomersCustomer"])

      assert PrefixedIds.resolve(@spec_map, parsed) ==
               {:ok,
                [
                  %{
                    prefix: "cus",
                    path: "/v1/customers/{customer}",
                    methods: [:get, :post, :delete]
                  }
                ]}
    end

    test "a path names itself" do
      parsed = parse!(prefixes: [sub: "/v1/subscriptions/{subscription_exposed_id}"])

      assert {:ok, [%{prefix: "sub", methods: [:get, :post]}]} =
               PrefixedIds.resolve(@spec_map, parsed)
    end

    test "an unknown operation or path is an error" do
      assert {:error, message} =
               PrefixedIds.resolve(@spec_map, parse!(prefixes: [cus: "NoSuchOp"]))

      assert message =~ "cus"
      assert message =~ "NoSuchOp"

      assert {:error, _} = PrefixedIds.resolve(@spec_map, parse!(prefixes: [x: "/v1/nope/{id}"]))
    end

    test "a resource path needs exactly one path parameter" do
      assert {:error, message} =
               PrefixedIds.resolve(@spec_map, parse!(prefixes: [src: "GetSource"]))

      assert message =~ "/v1/customers/{customer}/sources/{id}"
      assert message =~ "one path parameter"

      assert {:error, _} = PrefixedIds.resolve(@spec_map, parse!(prefixes: [c: "GetCustomers"]))
    end
  end

  describe "targets/3" do
    test "the operations the functions call: each resource path's methods a function uses" do
      parsed =
        parse!(
          functions: [retrieve: :get, update: :post],
          prefixes: [cus: "GetCustomersCustomer"]
        )

      {:ok, resources} = PrefixedIds.resolve(@spec_map, parsed)

      ids =
        @spec_map
        |> Operation.extract()
        |> PrefixedIds.targets(resources, parsed.functions)
        |> Enum.map(& &1.operation_id)
        |> Enum.sort()

      assert ids == ["GetCustomersCustomer", "PostCustomersCustomer"]
    end
  end

  describe "pairs/2" do
    test "which prefixes each function works for" do
      parsed =
        parse!(
          functions: [retrieve: :get, update: :post, delete: :delete],
          prefixes: [cus: "GetCustomersCustomer", sub: "GetSubscriptionsSubscriptionExposedId"]
        )

      {:ok, resources} = PrefixedIds.resolve(@spec_map, parsed)

      assert PrefixedIds.pairs(resources, parsed.functions) == [
               retrieve: ["cus", "sub"],
               update: ["cus", "sub"],
               delete: ["cus"]
             ]
    end
  end
end
