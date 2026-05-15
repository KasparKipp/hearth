defmodule Hearth.Spec.FilterTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Filter
  alias Hearth.Spec.Operation

  defp op(id, tags), do: %Operation{id: id, tags: tags}

  describe "parse/1" do
    test "a bare tag name means :all for that tag" do
      assert Filter.parse("Customers") == {:ok, [{"Customers", :all}]}
    end

    test "tag names keep internal whitespace" do
      assert Filter.parse("Payment Methods") == {:ok, [{"Payment Methods", :all}]}
    end

    test "colon narrows a tag to specific operationIds" do
      assert Filter.parse("Subscriptions:create_subscription,list_subscriptions") ==
               {:ok, [{"Subscriptions", {:only, ["create_subscription", "list_subscriptions"]}}]}
    end

    test "semicolon separates multiple tag-specs" do
      assert Filter.parse("Customers;Subscriptions:create_subscription") ==
               {:ok,
                [
                  {"Customers", :all},
                  {"Subscriptions", {:only, ["create_subscription"]}}
                ]}
    end

    test "trims whitespace around delimiters" do
      assert Filter.parse(" Customers ; Subscriptions : create , update ") ==
               {:ok, [{"Customers", :all}, {"Subscriptions", {:only, ["create", "update"]}}]}
    end

    test "rejects an empty filter string" do
      assert {:error, msg} = Filter.parse("")
      assert msg =~ "empty"
    end

    test "empty segments between semicolons are trimmed away, not errors" do
      assert Filter.parse("Customers;;Invoices") ==
               {:ok, [{"Customers", :all}, {"Invoices", :all}]}
    end

    test "repeated tag specs merge, unioning and sorting their operationIds" do
      assert Filter.parse("Customers:update;Invoices;Customers:create") ==
               {:ok, [{"Customers", {:only, ["create", "update"]}}, {"Invoices", :all}]}
    end

    test "a bare tag and a narrowed one for the same tag merge to the narrowed set" do
      assert Filter.parse("Customers;Customers:create") ==
               {:ok, [{"Customers", {:only, ["create"]}}]}
    end

    test "rejects an empty tag name (leading colon)" do
      assert {:error, msg} = Filter.parse(":create")
      assert msg =~ "empty tag name"
    end

    test "rejects a trailing colon with no operationIds" do
      assert {:error, msg} = Filter.parse("Subscriptions:")
      assert msg =~ "no operationIds"
    end
  end

  describe "apply/2" do
    setup do
      %{
        ops: [
          op("list_customers", ["Customers"]),
          op("create_customer", ["Customers"]),
          op("list_subscriptions", ["Subscriptions"]),
          op("create_subscription", ["Subscriptions"]),
          op("ping", [])
        ]
      }
    end

    test ":all keeps every operation", %{ops: ops} do
      assert Filter.apply(ops, :all) == ops
    end

    test "a whole-tag rule keeps every operation under that tag", %{ops: ops} do
      kept = Filter.apply(ops, [{"Customers", :all}])
      assert Enum.map(kept, & &1.id) == ["list_customers", "create_customer"]
    end

    test "an :only rule narrows to named operationIds", %{ops: ops} do
      kept = Filter.apply(ops, [{"Subscriptions", {:only, ["create_subscription"]}}])
      assert Enum.map(kept, & &1.id) == ["create_subscription"]
    end

    test "multiple rules union their matches", %{ops: ops} do
      kept =
        Filter.apply(ops, [
          {"Customers", {:only, ["create_customer"]}},
          {"Subscriptions", :all}
        ])

      assert Enum.map(kept, & &1.id) ==
               ["create_customer", "list_subscriptions", "create_subscription"]
    end

    test "operations matching no rule are excluded", %{ops: ops} do
      kept = Filter.apply(ops, [{"Customers", :all}])
      refute Enum.any?(kept, &(&1.id == "ping"))
      refute Enum.any?(kept, &(&1.id == "list_subscriptions"))
    end
  end

  describe "parse/1 + apply/2 round-trip" do
    test "a parsed filter selects the expected operations" do
      ops = [
        op("list_customers", ["Customers"]),
        op("create_subscription", ["Subscriptions"]),
        op("list_subscriptions", ["Subscriptions"])
      ]

      {:ok, filter} = Filter.parse("Customers;Subscriptions:create_subscription")
      kept = Filter.apply(ops, filter)

      assert Enum.map(kept, & &1.id) == ["list_customers", "create_subscription"]
    end
  end
end
