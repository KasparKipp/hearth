defmodule Mix.Tasks.Hearth.PrefixedIdsTest do
  use Hearth.TaskCase, async: true

  # `prefixed_ids:` in a `.hearth.exs` entry, across gen, regen, diff and
  # --sync. The spec is Stripe-like: untagged, so the entry tags the one
  # operation it generates as a function.

  @spec_json JSON.encode!(%{
               "openapi" => "3.0.0",
               "info" => %{"title" => "Shop", "version" => "1"},
               "servers" => [%{"url" => "https://api.shop.test"}],
               "paths" => %{
                 "/v1/customers" => %{"get" => %{"operationId" => "ListCustomers"}},
                 "/v1/customers/{customer}" => %{
                   "get" => %{"operationId" => "GetCustomer"},
                   "post" => %{"operationId" => "UpdateCustomer"},
                   "delete" => %{"operationId" => "DeleteCustomer"}
                 },
                 "/v1/subscriptions/{id}" => %{
                   "get" => %{"operationId" => "GetSubscription"},
                   "post" => %{"operationId" => "UpdateSubscription"},
                   "patch" => %{"operationId" => "PatchSubscription"}
                 }
               }
             })

  @prefixed [
    functions: [retrieve: :get, update: :post, delete: :delete],
    prefixes: [cus: "GetCustomer", sub: "/v1/subscriptions/{id}"]
  ]

  @api "lib/test/integrations/shop/shop_api.ex"
  @layer1 "lib/test/integrations/shop.ex"

  defp stub(extra) do
    entry = [overrides: [tags: [Customers: ["get /v1/customers"]]]] ++ extra
    "[integrations: [shop: #{inspect(entry)}]]"
  end

  defp gen(extra \\ [prefixed_ids: @prefixed]) do
    test_project(files: %{"priv/specs/shop.json" => @spec_json, ".hearth.exs" => stub(extra)})
    |> Igniter.compose_task("hearth.gen", [
      "priv/specs/shop.json",
      "--integration",
      "Shop",
      "--tag",
      "Customers"
    ])
  end

  defp entry(igniter) do
    igniter = Igniter.include_existing_file(igniter, ".hearth.exs")
    {:ok, [shop: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()
    entry
  end

  defp pruned_operations(igniter) do
    igniter
    |> created_file("priv/hearth/shop.yaml")
    |> YamlElixir.read_from_string!()
    |> Map.fetch!("paths")
    |> Enum.flat_map(fn {path, ops} -> Enum.map(Map.keys(ops), &"#{&1} #{path}") end)
    |> Enum.sort()
  end

  describe "gen" do
    test "adds the functions, without generating the target operations" do
      igniter = gen()
      api = created_file(igniter, @api)

      assert api =~ "@callback retrieve(id :: String.t(), opts :: keyword())"
      assert api =~ "def update(id, opts \\\\ []), do: impl().update(id, opts)"
      assert api =~ "Works for: cus, sub."
      assert api =~ "def list_customers("
      refute api =~ "def get_customer("

      layer1 = created_file(igniter, @layer1)

      assert layer1 =~ ~s|defp parse_url("cus_" <> _ = id), do: "/customers/\#{id}"|
      assert layer1 =~ ~s|defp parse_url("sub_" <> _ = id), do: "/subscriptions/\#{id}"|
      assert layer1 =~ "Req.request(new(url: parse_url(url)), opts)"
    end

    test "a selected operation a prefixed function covers gets no function of its own" do
      # The tag override also selects GET /v1/customers/{customer}, which
      # `retrieve/2` covers for cus_ ids.
      igniter =
        test_project(
          files: %{
            "priv/specs/shop.json" => @spec_json,
            ".hearth.exs" =>
              "[integrations: [shop: #{inspect(overrides: [tags: [Customers: ["get /v1/customers", "get /v1/customers/{customer}"]]], prefixed_ids: @prefixed)}]]"
          }
        )
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/shop.json",
          "--integration",
          "Shop",
          "--tag",
          "Customers"
        ])

      api = created_file(igniter, @api)
      assert api =~ "def list_customers("
      refute api =~ "def get_customer("

      refute created_file(igniter, "test/test/integrations/shop_external_test.exs") =~
               "get_customer"

      assert notice_text(igniter) =~
               "get /v1/customers/{customer} (GetCustomer) — through retrieve/2"

      assert entry(igniter)[:tags] == [Customers: :all]

      regen = igniter |> apply_igniter!() |> Igniter.compose_task("hearth.regen", ["shop"])
      assert_unchanged(regen)
    end

    test "keeps the target operations the functions use in the pruned spec" do
      assert pruned_operations(gen()) == [
               "delete /v1/customers/{customer}",
               "get /v1/customers",
               "get /v1/customers/{customer}",
               "get /v1/subscriptions/{id}",
               "post /v1/customers/{customer}",
               "post /v1/subscriptions/{id}"
             ]
    end

    test "the notice lists which prefixes each function works for" do
      notices = notice_text(gen())

      assert notices =~ "Test.Integrations.Shop.ShopApi.retrieve/2 — cus, sub"
      assert notices =~ "Test.Integrations.Shop.ShopApi.delete/2 — cus"
    end

    test "keeps prefixed_ids in the entry; tags: records only the selection" do
      entry = entry(gen())

      assert entry[:prefixed_ids] == @prefixed
      assert entry[:untagged] == :none
      assert entry[:tags] == [Customers: :all]
    end

    test "regen and diff are clean right after gen" do
      igniter = gen() |> apply_igniter!()

      igniter |> Igniter.compose_task("hearth.regen", ["shop"]) |> assert_unchanged()

      assert igniter |> Igniter.compose_task("hearth.diff", ["shop"]) |> notice_text() =~
               "no drift"
    end

    test "halts on a function name an operation function already uses" do
      prefixed = [functions: [list_customers: :get], prefixes: [cus: "GetCustomer"]]

      assert gen(prefixed_ids: prefixed) |> issue_text() =~
               "defines `list_customers`, which a generated operation function already uses"
    end

    test "halts on a prefix target the spec doesn't have" do
      prefixed = [prefixes: [cus: "NoSuchOperation"]]

      assert gen(prefixed_ids: prefixed) |> issue_text() =~
               ~s|prefix cus names the operation "NoSuchOperation"|
    end
  end

  describe "added later" do
    test "diff shows the target operations joining the pruned spec; --sync adds the functions" do
      igniter = gen([]) |> apply_igniter!() |> Igniter.include_existing_file(".hearth.exs")

      exs =
        igniter
        |> created_file(".hearth.exs")
        |> String.replace(
          "module: Test.Integrations.Shop,",
          "module: Test.Integrations.Shop, prefixed_ids: #{inspect(@prefixed)},"
        )

      igniter =
        igniter
        |> Igniter.create_new_file(".hearth.exs", exs, on_exists: :overwrite)
        |> apply_igniter!()

      assert igniter |> Igniter.compose_task("hearth.diff", ["shop"]) |> issue_text() =~
               "+ get /v1/customers/{customer} (GetCustomer)"

      synced = Igniter.compose_task(igniter, "hearth.regen", ["shop", "--sync"])
      assert created_file(synced, @api) =~ "def retrieve(id, opts"
      refute created_file(synced, @api) =~ "def get_customer("
    end
  end
end
