defmodule Hearth.Spec.OverridesTest do
  use ExUnit.Case, async: true

  alias Hearth.Spec.Overrides

  # Stripe-like: no tags anywhere.
  @spec_map %{
    "paths" => %{
      "/v1/customers" => %{
        "get" => %{"operationId" => "GetCustomers"},
        "post" => %{"operationId" => "PostCustomers"}
      },
      "/v1/customers/{customer}/balance" => %{
        "get" => %{"operationId" => "GetCustomersCustomerBalance"}
      },
      "/v1/customers/search" => %{"get" => %{"operationId" => "GetCustomersSearch"}},
      "/v1/invoices" => %{
        "get" => %{"operationId" => "GetInvoices"},
        "post" => %{"operationId" => "PostInvoices", "tags" => ["Billing"]}
      },
      "/v1/health" => %{"get" => %{}}
    }
  }

  defp tags_of(spec, path, method), do: get_in(spec, ["paths", path, method, "tags"])

  describe "parse/1" do
    test "reads the overrides block of an entry" do
      assert {:ok, %{tags: [{"Customers", ["/v1/customers*"]}], operation_ids: %{}}} =
               Overrides.parse(overrides: [tags: [Customers: ["/v1/customers*"]]])
    end

    test "an entry without overrides has none" do
      assert Overrides.parse(module: X) == {:ok, %{tags: [], operation_ids: %{}}}
    end

    test "rejects malformed tags and unknown override kinds" do
      assert {:error, message} = Overrides.parse(overrides: [tags: [Customers: "/v1/customers*"]])
      assert message =~ "tags:"

      assert {:error, message} = Overrides.parse(overrides: [patches: []])
      assert message =~ "patches"
      assert message =~ "operation_ids"

      assert {:error, _} = Overrides.parse(overrides: :nope)
    end
  end

  describe "apply/2 with tags" do
    defp apply_tags(tags) do
      {:ok, overrides} = Overrides.parse(overrides: [tags: tags])
      {:ok, spec, stale} = Overrides.apply(@spec_map, overrides)
      {spec, stale}
    end

    test "a path glob tags every operation under it — `*` crosses `/`" do
      {spec, []} = apply_tags(Customers: ["/v1/customers*"])

      assert tags_of(spec, "/v1/customers", "get") == ["Customers"]
      assert tags_of(spec, "/v1/customers", "post") == ["Customers"]
      assert tags_of(spec, "/v1/customers/{customer}/balance", "get") == ["Customers"]
      assert tags_of(spec, "/v1/invoices", "get") == nil
    end

    test "a method narrows a glob" do
      {spec, []} = apply_tags(Reads: ["get /v1/customers"])

      assert tags_of(spec, "/v1/customers", "get") == ["Reads"]
      assert tags_of(spec, "/v1/customers", "post") == nil
    end

    test "anything else is an operationId" do
      {spec, []} = apply_tags(Search: ["GetCustomersSearch"])

      assert tags_of(spec, "/v1/customers/search", "get") == ["Search"]
      assert tags_of(spec, "/v1/customers", "get") == nil
    end

    test "adds to upstream tags without duplicating" do
      {spec, []} = apply_tags(Billing: ["/v1/invoices"], Money: ["/v1/invoices"])

      assert tags_of(spec, "/v1/invoices", "post") == ["Billing", "Money"]
      assert tags_of(spec, "/v1/invoices", "get") == ["Billing", "Money"]
    end

    test "entries that match nothing come back as stale" do
      {_spec, stale} =
        apply_tags(Customers: ["/v1/custmers*", "GetCustomers"], Gone: ["NoSuchOp"])

      assert stale == [{:tags, ~s|Customers: "/v1/custmers*"|}, {:tags, ~s|Gone: "NoSuchOp"|}]
    end

    test "no overrides leaves the spec as it is" do
      assert Overrides.apply(@spec_map, %{tags: [], operation_ids: %{}}) == {:ok, @spec_map, []}
    end
  end

  describe "apply/2 with operation_ids" do
    defp rename(overrides) do
      {:ok, parsed} = Overrides.parse(overrides: overrides)
      Overrides.apply(@spec_map, parsed)
    end

    defp id_of(spec, path, method), do: get_in(spec, ["paths", path, method, "operationId"])

    test "renames by upstream operationId" do
      {:ok, spec, []} = rename(operation_ids: %{"GetCustomersCustomerBalance" => "GetBalance"})

      assert id_of(spec, "/v1/customers/{customer}/balance", "get") == "GetBalance"
    end

    test "names an operation without an id by method and path" do
      {:ok, spec, []} = rename(operation_ids: %{"get /v1/health" => "Health"})

      assert id_of(spec, "/v1/health", "get") == "Health"
    end

    test "tag overrides match the upstream id, not the new one" do
      {:ok, spec, []} =
        rename(
          tags: [Search: ["GetCustomersSearch"]],
          operation_ids: %{"GetCustomersSearch" => "SearchCustomers"}
        )

      assert id_of(spec, "/v1/customers/search", "get") == "SearchCustomers"
      assert tags_of(spec, "/v1/customers/search", "get") == ["Search"]
    end

    test "a key that matches nothing is stale" do
      {:ok, _spec, stale} = rename(operation_ids: %{"NoSuchOp" => "Whatever"})

      assert stale == [{:operation_ids, ~s|"NoSuchOp"|}]
    end

    test "renaming onto another operation's id halts" do
      assert {:error, message} = rename(operation_ids: %{"GetCustomersSearch" => "GetCustomers"})
      assert message =~ "GetCustomers"
      assert message =~ "get /v1/customers/search"
      assert message =~ "get /v1/customers"
    end

    test "renaming onto another operation's function name halts" do
      assert {:error, message} = rename(operation_ids: %{"GetInvoices" => "getCustomers"})
      assert message =~ "get_customers"
    end

    test "two renames to the same id halt" do
      assert {:error, _} =
               rename(operation_ids: %{"GetInvoices" => "List", "GetCustomers" => "List"})
    end

    test "rejects a malformed map" do
      assert {:error, message} = Overrides.parse(overrides: [operation_ids: [GetCustomers: "X"]])
      assert message =~ "operation_ids:"

      assert {:error, _} = Overrides.parse(overrides: [operation_ids: %{"GetCustomers" => :x}])
    end
  end
end
