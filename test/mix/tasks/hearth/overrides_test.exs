defmodule Mix.Tasks.Hearth.OverridesTest do
  use Hearth.TaskCase, async: true

  # `overrides:` in a `.hearth.exs` entry, across gen, regen and diff.
  # The spec is Stripe-like: no operation has a tag.

  @spec_json JSON.encode!(%{
               "openapi" => "3.0.0",
               "info" => %{"title" => "Shop", "version" => "1"},
               "servers" => [%{"url" => "https://api.shop.test"}],
               "paths" => %{
                 "/v1/customers" => %{
                   "get" => %{"operationId" => "GetCustomers"},
                   "post" => %{"operationId" => "PostCustomers"}
                 },
                 "/v1/customers/search" => %{"get" => %{"operationId" => "GetCustomersSearch"}},
                 "/v1/invoices" => %{"get" => %{"operationId" => "GetInvoices"}}
               }
             })

  defp stub(overrides) do
    "[integrations: [shop: [overrides: #{inspect(overrides)}]]]"
  end

  defp gen(overrides, tag_args \\ ["--tag", "Customers"]) do
    test_project(files: %{"priv/specs/shop.json" => @spec_json, ".hearth.exs" => stub(overrides)})
    |> Igniter.compose_task(
      "hearth.gen",
      ["priv/specs/shop.json", "--integration", "Shop"] ++ tag_args
    )
  end

  defp entry(igniter) do
    {:ok, [shop: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  defp pruned(igniter),
    do: igniter |> created_file("priv/hearth/shop.yaml") |> YamlElixir.read_from_string!()

  describe "gen" do
    test "tags an untagged spec, so --tag can select from it" do
      igniter = gen(tags: [Customers: ["/v1/customers*"]])

      assert igniter.issues == []
      api = created_file(igniter, "lib/test/integrations/shop/shop_api.ex")
      assert api =~ "def get_customers("
      assert api =~ "def get_customers_search("
      refute api =~ "def get_invoices("
    end

    test "the pruned spec carries the override tags" do
      igniter = gen(tags: [Customers: ["/v1/customers*"]])

      assert pruned(igniter)["paths"]["/v1/customers"]["get"]["tags"] == ["Customers"]
    end

    test "keeps the overrides in the entry, and records the selection" do
      overrides = [tags: [Customers: ["/v1/customers*"]]]
      entry = entry(gen(overrides))

      assert entry[:overrides] == overrides
      assert entry[:tags] == [Customers: :all]
      assert entry[:untagged] == :none
      assert entry[:module] == Test.Integrations.Shop
    end

    test "a method glob and an operationId narrow the tag" do
      igniter = gen(tags: [Customers: ["get /v1/customers", "GetCustomersSearch"]])
      api = created_file(igniter, "lib/test/integrations/shop/shop_api.ex")

      assert api =~ "def get_customers("
      assert api =~ "def get_customers_search("
      refute api =~ "def post_customers("
    end

    test "reports override entries that match nothing" do
      igniter = gen(tags: [Customers: ["/v1/customers*", "/v1/custmers*"]])

      assert notice_text(igniter) =~ "Overrides for shop that match nothing"
      assert notice_text(igniter) =~ ~s|tags Customers: "/v1/custmers*"|
    end

    test "halts on malformed overrides" do
      igniter = gen(tags: [Customers: "/v1/customers*"])

      assert issue_text(igniter) =~ "malformed `overrides:`"
    end

    test "halts on an override kind that doesn't exist yet" do
      igniter = gen(operation_ids: %{"GetCustomers" => "ListCustomers"})

      assert issue_text(igniter) =~ "unknown override `operation_ids:`"
    end
  end

  describe "regen and diff" do
    defp generated, do: gen(tags: [Customers: ["get /v1/customers"]]) |> apply_igniter!()

    # Adds one entry to the Customers tag override.
    defp add_override(igniter, entry) do
      igniter = Igniter.include_existing_file(igniter, ".hearth.exs")

      exs =
        igniter
        |> created_file(".hearth.exs")
        |> String.replace(~s|"get /v1/customers"]|, ~s|"get /v1/customers", #{inspect(entry)}]|)

      igniter
      |> Igniter.create_new_file(".hearth.exs", exs, on_exists: :overwrite)
      |> apply_igniter!()
    end

    test "regen right after gen is a no-op, and diff sees no drift" do
      igniter = generated()

      igniter |> Igniter.compose_task("hearth.regen", ["shop"]) |> assert_unchanged()

      assert igniter |> Igniter.compose_task("hearth.diff", ["shop"]) |> notice_text() =~
               "no drift"
    end

    test "widening an override is drift that --sync applies" do
      igniter = generated() |> add_override("GetCustomersSearch")

      assert igniter |> Igniter.compose_task("hearth.diff", ["shop"]) |> issue_text() =~
               "+ get /v1/customers/search (GetCustomersSearch)"

      synced = Igniter.compose_task(igniter, "hearth.regen", ["shop", "--sync"])

      assert created_file(synced, "lib/test/integrations/shop/shop_api.ex") =~
               "def get_customers_search("
    end

    test "--sync and diff report stale overrides" do
      igniter = generated() |> add_override("NoSuchOp")

      assert igniter |> Igniter.compose_task("hearth.diff", ["shop"]) |> notice_text() =~
               ~s|tags Customers: "NoSuchOp"|

      assert igniter |> Igniter.compose_task("hearth.regen", ["shop", "--sync"]) |> notice_text() =~
               ~s|tags Customers: "NoSuchOp"|
    end
  end
end
