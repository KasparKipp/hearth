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
      assert {:ok, %{tags: [{"Customers", ["/v1/customers*"]}]}} =
               Overrides.parse(overrides: [tags: [Customers: ["/v1/customers*"]]])
    end

    test "an entry without overrides has none" do
      assert Overrides.parse(module: X) == {:ok, %{tags: []}}
    end

    test "rejects malformed tags and unknown override kinds" do
      assert {:error, message} = Overrides.parse(overrides: [tags: [Customers: "/v1/customers*"]])
      assert message =~ "tags:"

      assert {:error, message} = Overrides.parse(overrides: [operation_ids: %{}])
      assert message =~ "operation_ids"
      assert message =~ "tags"

      assert {:error, _} = Overrides.parse(overrides: :nope)
    end
  end

  describe "apply/2 with tags" do
    defp apply_tags(tags) do
      {:ok, overrides} = Overrides.parse(overrides: [tags: tags])
      Overrides.apply(@spec_map, overrides)
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

      assert stale == [{:tags, "Customers", "/v1/custmers*"}, {:tags, "Gone", "NoSuchOp"}]
    end

    test "no overrides leaves the spec as it is" do
      assert Overrides.apply(@spec_map, %{tags: []}) == {@spec_map, []}
    end
  end
end
