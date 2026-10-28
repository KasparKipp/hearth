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

    # Gen would keep only GetCustomer in the pruned spec, so regen
    # couldn't find UpdateCustomer: gen halts instead.
    test "halts on a prefix naming an operation no function calls" do
      prefixed = [functions: [retrieve: :get], prefixes: [cus: "UpdateCustomer"]]
      igniter = gen(prefixed_ids: prefixed)

      assert issue_text(igniter) =~
               "prefix cus names UpdateCustomer (post /v1/customers/{customer}), " <>
                 "but no function uses :post"

      assert issue_text(igniter) =~ "(GetCustomer)"
      refute Igniter.exists?(igniter, @layer1)
    end

    # Resolved once, before the pruned spec is checked against `tags:` —
    # here `:none` no longer selects ListCustomers either.
    test "regen halts on a prefix target the pruned spec doesn't have, before the selection" do
      issues =
        gen()
        |> apply_igniter!()
        |> Hearth.Config.Project.put_fields(:shop,
          prefixed_ids: [prefixes: [cus: "NoSuchOperation"]],
          tags: [Customers: :none]
        )
        |> apply_igniter!()
        |> Igniter.compose_task("hearth.regen", ["shop"])
        |> issue_text()

      assert issues =~
               "hearth.regen: the .hearth.exs entry for shop has a problem in `prefixed_ids:`"

      assert issues =~ ~s|prefix cus names the operation "NoSuchOperation"|
      refute issues =~ "doesn't select it"
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

  describe "a sync that covers an existing function" do
    # Subscriptions start with their own get_subscription/2, called from
    # app code, a Mox test and the external test; then `sub:` joins the
    # prefixes, and retrieve/2 covers it.
    @cus_only [functions: [retrieve: :get], prefixes: [cus: "GetCustomer"]]
    @with_sub [
      functions: [retrieve: :get],
      prefixes: [cus: "GetCustomer", sub: "GetSubscription"]
    ]

    @app "lib/test/billing.ex"
    @app_test "test/test/billing_test.exs"
    @external "test/test/integrations/shop_external_test.exs"

    defp gen_subscriptions do
      entry = [
        overrides: [
          tags: [Customers: ["get /v1/customers"], Subscriptions: ["get /v1/subscriptions/{id}"]]
        ],
        prefixed_ids: @cus_only
      ]

      test_project(
        files: %{
          "priv/specs/shop.json" => @spec_json,
          ".hearth.exs" => "[integrations: [shop: #{inspect(entry)}]]",
          @app => """
          defmodule Test.Billing do
            alias Test.Integrations.Shop.ShopApi

            def status(id), do: ShopApi.get_subscription(id)
            def status(id, opts), do: ShopApi.get_subscription(id, opts)
          end
          """,
          @app_test => """
          defmodule Test.BillingTest do
            use ExUnit.Case
            import Mox
            alias Test.Integrations.Shop.ShopApi

            test "status" do
              expect(ShopApi.Mock, :get_subscription, fn "sub_1", [] -> {:ok, %{}} end)
              Mox.stub(ShopApi.Mock, :get_subscription, fn _, _ -> {:ok, %{}} end)
            end
          end
          """
        }
      )
      |> Igniter.compose_task("hearth.gen", [
        "priv/specs/shop.json",
        "--integration",
        "Shop",
        "--tag",
        "Customers",
        "--tag",
        "Subscriptions"
      ])
      |> apply_igniter!()
    end

    defp set_prefixed(igniter, prefixed) do
      igniter
      |> Hearth.Config.Project.put_fields(:shop, prefixed_ids: prefixed)
      |> apply_igniter!()
    end

    defp add_sub(igniter), do: set_prefixed(igniter, @with_sub)

    defp read(igniter, path) do
      igniter |> Igniter.include_existing_file(path) |> created_file(path)
    end

    test "the setup generates get_subscription/2" do
      assert read(gen_subscriptions(), @api) =~ "def get_subscription("
    end

    test "--sync moves call sites, Mox expectations and the external test to retrieve/2" do
      synced =
        gen_subscriptions()
        |> add_sub()
        |> Igniter.compose_task("hearth.regen", ["shop", "--sync"])

      refute read(synced, @api) =~ "def get_subscription("

      app = read(synced, @app)
      assert app =~ "def status(id), do: ShopApi.retrieve(id)"
      assert app =~ "def status(id, opts), do: ShopApi.retrieve(id, opts)"

      app_test = read(synced, @app_test)
      assert app_test =~ "expect(ShopApi.Mock, :retrieve, fn"
      assert app_test =~ "Mox.stub(ShopApi.Mock, :retrieve, fn"

      assert read(synced, @external) =~ "ShopApi.Req.retrieve("
      refute read(synced, @external) =~ "ShopApi.Req.get_subscription("

      assert notice_text(synced) =~ "get_subscription → retrieve"
    end

    test "an operationId rename moves the call sites too" do
      igniter = gen_subscriptions() |> Igniter.include_existing_file(".hearth.exs")

      exs =
        igniter
        |> created_file(".hearth.exs")
        |> String.replace(
          ~s|Subscriptions: ["get /v1/subscriptions/{id}"]]|,
          ~s|Subscriptions: ["get /v1/subscriptions/{id}"]], operation_ids: %{"GetSubscription" => "FetchSubscription"}|
        )

      synced =
        igniter
        |> Igniter.create_new_file(".hearth.exs", exs, on_exists: :overwrite)
        |> apply_igniter!()
        |> Igniter.compose_task("hearth.regen", ["shop", "--sync"])

      assert read(synced, @app) =~ "ShopApi.fetch_subscription(id)"
      assert read(synced, @app_test) =~ "expect(ShopApi.Mock, :fetch_subscription, fn"
      assert notice_text(synced) =~ "get_subscription → fetch_subscription"
    end

    test "dropping a prefix gives the operation its function back, with an external test" do
      synced =
        gen_subscriptions()
        |> add_sub()
        |> Igniter.compose_task("hearth.regen", ["shop", "--sync"])
        |> apply_igniter!()
        |> set_prefixed(@cus_only)
        |> Igniter.compose_task("hearth.regen", ["shop", "--sync"])

      assert read(synced, @api) =~ "def get_subscription("
      assert read(synced, @external) =~ "ShopApi.Req.get_subscription("
    end
  end
end
