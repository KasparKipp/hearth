defmodule Mix.Tasks.Hearth.RegenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

  # A pruned spec is plain OpenAPI; `.hearth.exs` names each
  # integration's Layer 1 module (plus gen's source and base path).
  @petstore_entry "petstore: [module: Test.Integrations.Petstore]"
  @shop_entry ~s|shop: [module: Test.Integrations.Shop, source: "priv/specs/shop.json", base_path: ""]|

  @shop_pruned """
  openapi: 3.0.0
  info: {title: Shop, version: "1.0"}
  servers: [{url: "https://api.example.com"}]
  paths:
    /customers:
      get: {operationId: listCustomers}
  """

  @petstore %{
    "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
    ".hearth.exs" => "[integrations: [#{@petstore_entry}]]"
  }

  @petstore_and_shop %{
    "priv/hearth/petstore.yaml" => @petstore_3_0_yaml,
    "priv/hearth/shop.yaml" => @shop_pruned,
    ".hearth.exs" => "[integrations: [#{@petstore_entry}, #{@shop_entry}]]"
  }

  @layer1 "lib/test/integrations/petstore.ex"
  @layer2 "lib/test/integrations/petstore/petstore_api.ex"
  @layer3 "lib/test/integrations/petstore/petstore_api/req.ex"
  @external "test/test/integrations/petstore_external_test.exs"
  @shop_layer1 "lib/test/integrations/shop.ex"

  defp notice_text(igniter), do: Enum.join(igniter.notices, "\n\n")

  defp created_file(igniter, path) do
    {:ok, source} = Rewrite.source(igniter.rewrite, path)
    Rewrite.Source.get(source, :content)
  end

  defp has_issue?(igniter, fragments) do
    Enum.any?(igniter.issues, fn issue ->
      Enum.all?(fragments, &String.contains?(issue, &1))
    end)
  end

  defp owned_layer1 do
    """
    defmodule Test.Integrations.Petstore do
      @moduledoc \"\"\"
      Raw client.

      hearth:owned
      \"\"\"
      def hand_written, do: :mine
    end
    """
  end

  defp regen(igniter, argv \\ ["petstore"]),
    do: Igniter.compose_task(igniter, "hearth.regen", argv)

  describe "the pruned spec" do
    test "regenerates the layers from priv/hearth/<name>.yaml" do
      igniter =
        test_project(files: @petstore)
        |> regen()

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @layer2)
      assert_creates(igniter, @layer3)

      assert created_file(igniter, @layer1) =~ "defmodule Test.Integrations.Petstore do"
      assert created_file(igniter, @layer2) =~ "@callback list_pets("
    end

    test "halts when the pruned spec is missing" do
      igniter =
        test_project(files: Map.delete(@petstore, "priv/hearth/petstore.yaml"))
        |> regen()

      assert has_issue?(igniter, ["no pruned spec for Petstore", "priv/hearth/petstore.yaml"])
    end

    test "is plain OpenAPI: regen leaves it untouched" do
      test_project(files: @petstore)
      |> regen()
      |> assert_unchanged("priv/hearth/petstore.yaml")
    end
  end

  describe "naming integrations" do
    test "halts with a helpful message when nothing is named and --all is absent" do
      igniter =
        test_project(files: @petstore)
        |> regen([])

      assert has_issue?(igniter, ["--all", "mix hearth.regen stripe"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end

    test "the name is case-insensitive: Petstore reads priv/hearth/petstore.yaml" do
      test_project(files: @petstore)
      |> regen(["Petstore"])
      |> assert_creates(@layer1)
    end

    test "a snake_case name maps to its snake_case entry and pruned spec" do
      files = %{
        "priv/hearth/send_grid.yaml" => @petstore_3_0_yaml,
        ".hearth.exs" => "[integrations: [send_grid: [module: Test.Integrations.SendGrid]]]"
      }

      test_project(files: files)
      |> regen(["SendGrid"])
      |> assert_creates("lib/test/integrations/send_grid.ex")
    end

    test "comma-separated names regenerate each integration" do
      igniter =
        test_project(files: @petstore_and_shop)
        |> regen(["petstore, shop"])

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @shop_layer1)
      assert notice_text(igniter) =~ "Regenerated Test.Integrations.Petstore"
      assert notice_text(igniter) =~ "Regenerated Test.Integrations.Shop"
    end

    test "one missing integration halts the whole run" do
      igniter =
        test_project(files: @petstore)
        |> regen(["petstore,stripe"])

      assert has_issue?(igniter, ["stripe", ".hearth.exs"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end

    test "halts when .hearth.exs has no entry for the integration" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_3_0_yaml})
        |> regen()

      assert has_issue?(igniter, ["no integration named petstore", ".hearth.exs"])
    end

    test "halts when .hearth.exs can't be read" do
      igniter =
        test_project(files: Map.put(@petstore, ".hearth.exs", "[integrations: :oops]"))
        |> regen()

      assert has_issue?(igniter, [".hearth.exs", "integrations:"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end

    test "rejects a name that isn't a single alias segment" do
      igniter =
        test_project(files: @petstore)
        |> regen(["Test.Integrations.Petstore"])

      assert has_issue?(igniter, ["\"Test.Integrations.Petstore\"", "integration name"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end

    test "--all regenerates every integration in .hearth.exs" do
      igniter =
        test_project(files: @petstore_and_shop)
        |> regen(["--all"])

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @shop_layer1)
    end

    test "--all skips a pruned spec with no entry" do
      igniter =
        test_project(files: Map.put(@petstore, "priv/hearth/shop.yaml", @shop_pruned))
        |> regen(["--all"])

      assert_creates(igniter, @layer1)
      refute Rewrite.has_source?(igniter.rewrite, @shop_layer1)
    end

    test "--all halts when .hearth.exs has no integrations" do
      for files <- [%{}, %{".hearth.exs" => "[integrations: []]"}] do
        igniter =
          test_project(files: files)
          |> regen(["--all"])

        assert has_issue?(igniter, ["no integrations", ".hearth.exs"])
      end
    end

    test "--all together with names halts rather than guess" do
      igniter =
        test_project(files: @petstore)
        |> regen(["petstore", "--all"])

      assert has_issue?(igniter, ["--all"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end
  end

  describe "--module" do
    @billing_layer1 "lib/test/billing/petstore.ex"

    defp gen_petstore do
      test_project(files: %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml})
      |> Igniter.compose_task("hearth.gen", [
        "priv/specs/petstore.yaml",
        "--integration",
        "Petstore"
      ])
      |> apply_igniter!()
    end

    defp move_petstore(igniter),
      do: regen(igniter, ["petstore", "--module", "Test.Billing.Petstore"])

    test "regenerates into the new module and leaves the old one untouched" do
      igniter = gen_petstore() |> move_petstore()

      assert_creates(igniter, @billing_layer1)
      assert_creates(igniter, "lib/test/billing/petstore/petstore_api.ex")
      assert_creates(igniter, "lib/test/billing/petstore/petstore_api/req.ex")
      assert_creates(igniter, "test/test/billing/petstore_test.exs")
      assert_creates(igniter, "test/test/billing/petstore_external_test.exs")
      assert created_file(igniter, @billing_layer1) =~ "defmodule Test.Billing.Petstore do"

      assert_unchanged(igniter, [@layer1, @layer2, @layer3, @external])
    end

    test "points the .hearth.exs entry at the new module, leaving the pruned spec alone" do
      igniter = gen_petstore() |> move_petstore()

      {:ok, [petstore: entry]} = igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()

      assert entry[:module] == Test.Billing.Petstore
      assert entry[:source] == "priv/specs/petstore.yaml"
      assert_unchanged(igniter, "priv/hearth/petstore.yaml")
    end

    test "wires the new module's mock and config like gen does" do
      igniter = gen_petstore() |> move_petstore()

      assert created_file(igniter, "test/support/mocks.ex") =~
               "Mox.defmock(Test.Billing.Petstore.PetstoreApi.Mock,"

      test_config = created_file(igniter, "config/test.exs")
      assert test_config =~ "impl: Test.Billing.Petstore.PetstoreApi.Mock"
      assert test_config =~ "impl: Test.Integrations.Petstore.PetstoreApi.Mock"
    end

    test "the notice says the old module was left in place" do
      notice = gen_petstore() |> move_petstore() |> notice_text()

      assert notice =~ "Test.Integrations.Petstore"
      assert notice =~ "Test.Billing.Petstore"
      assert notice =~ @layer1
    end

    test "a later regen refreshes the new module and is a no-op" do
      gen_petstore()
      |> move_petstore()
      |> apply_igniter!()
      |> regen()
      |> assert_unchanged()
    end

    test "the current module is a plain regen" do
      gen_petstore()
      |> regen(["petstore", "--module", "Test.Integrations.Petstore"])
      |> assert_unchanged()
    end

    test "halts when the new module's files already exist" do
      igniter =
        test_project(
          files: Map.put(@petstore, @billing_layer1, "defmodule Test.Billing.Petstore do\nend\n")
        )
        |> move_petstore()

      assert has_issue?(igniter, ["Test.Billing.Petstore already exists", @billing_layer1])
    end

    test "needs exactly one integration" do
      files = @petstore_and_shop

      for argv <- [
            ["petstore,shop", "--module", "Test.Billing.Petstore"],
            ["--all", "--module", "Test.Billing.Petstore"]
          ] do
        igniter = test_project(files: files) |> regen(argv)
        assert has_issue?(igniter, ["--module", "exactly one integration"])
      end
    end

    test "rejects a value that isn't a module name" do
      igniter =
        test_project(files: @petstore)
        |> regen(["petstore", "--module", "test.billing.petstore"])

      assert has_issue?(igniter, ["--module", "\"test.billing.petstore\""])
    end

    test "rejects a module that renames the integration" do
      igniter =
        test_project(files: @petstore)
        |> regen(["petstore", "--module", "Test.Billing.PetstoreV2"])

      assert has_issue?(igniter, ["Test.Billing.PetstoreV2", "must end in Petstore"])
    end
  end

  describe "--remove-old" do
    # API-key auth (a runtime.exs credential) and extra servers
    # (commented alternates in config.exs and test.exs), so every kind
    # of config entry `gen` writes is present.
    @keyed_spec JSON.encode!(%{
                  "openapi" => "3.0.0",
                  "info" => %{"title" => "Keyed", "version" => "1.0"},
                  "servers" => [
                    %{"url" => "https://api.keyed.com"},
                    %{"url" => "https://eu.keyed.com"},
                    %{"url" => "https://sandbox.keyed.com"},
                    %{"url" => "https://staging.keyed.com"}
                  ],
                  "paths" => %{"/ping" => %{"get" => %{"operationId" => "ping"}}},
                  "components" => %{
                    "securitySchemes" => %{
                      "ApiKey" => %{"type" => "apiKey", "in" => "header", "name" => "X-API-Key"}
                    }
                  }
                })

    @old_keyed_files [
      "lib/test/integrations/keyed.ex",
      "lib/test/integrations/keyed/keyed_api.ex",
      "lib/test/integrations/keyed/keyed_api/req.ex",
      "test/test/integrations/keyed_test.exs"
    ]
    @config_files ~w(config/config.exs config/test.exs config/runtime.exs test/support/mocks.ex)

    # Two integrations, so removing one must leave the other's config.
    defp gen_keyed_and_petstore do
      test_project(
        files: %{
          "priv/specs/keyed.json" => @keyed_spec,
          "priv/specs/petstore.yaml" => @petstore_3_0_yaml
        }
      )
      |> Igniter.compose_task("hearth.gen", ["priv/specs/keyed.json", "--integration", "Keyed"])
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.gen", [
        "priv/specs/petstore.yaml",
        "--integration",
        "Petstore"
      ])
      |> apply_igniter!()
    end

    defp move_keyed(igniter, extra \\ ["--remove-old"]) do
      regen(igniter, ["keyed", "--module", "Test.Billing.Keyed"] ++ extra)
    end

    defp contents(igniter, paths), do: Enum.map_join(paths, "\n", &created_file(igniter, &1))

    test "the setup writes every kind of config entry for the old module" do
      config = gen_keyed_and_petstore() |> contents(@config_files)

      assert config =~ ~r/Test\.Integrations\.Keyed,\s+api_key:/
      assert config =~ "Test.Integrations.Keyed, base_url:"
      assert config =~ "impl: Test.Integrations.Keyed.KeyedApi.Mock"
      assert config =~ "# Hearth: alternate base URLs for Test.Integrations.Keyed"
      assert config =~ "Mox.defmock(Test.Integrations.Keyed.KeyedApi.Mock"
    end

    test "removes the old module's files" do
      gen_keyed_and_petstore()
      |> move_keyed()
      |> assert_rms(@old_keyed_files)
    end

    test "removes every config entry for the old module, keeping the others" do
      config = gen_keyed_and_petstore() |> move_keyed() |> contents(@config_files)

      refute config =~ "Test.Integrations.Keyed"
      assert config =~ ~r/Test\.Billing\.Keyed,\s+api_key:/
      assert config =~ "impl: Test.Billing.Keyed.KeyedApi.Mock"
      assert config =~ "impl: Test.Integrations.Petstore.PetstoreApi.Mock"
      assert config =~ "Mox.defmock(Test.Integrations.Petstore.PetstoreApi.Mock"
    end

    test "leaves no empty config_env blocks behind in runtime.exs" do
      runtime =
        test_project(files: %{"priv/specs/keyed.json" => @keyed_spec})
        |> Igniter.compose_task("hearth.gen", ["priv/specs/keyed.json", "--integration", "Keyed"])
        |> apply_igniter!()
        |> move_keyed()
        |> created_file("config/runtime.exs")

      assert runtime =~ ~r/Test\.Billing\.Keyed,\s+api_key:/
      refute runtime =~ ~r/do\s+end/
    end

    test "keeps the user-owned external test scaffold and lists it" do
      igniter = gen_keyed_and_petstore() |> move_keyed()

      refute "test/test/integrations/keyed_external_test.exs" in igniter.rms
      assert notice_text(igniter) =~ "test/test/integrations/keyed_external_test.exs"
    end

    test "keeps an old file marked hearth:owned and lists it" do
      owned = """
      defmodule Test.Integrations.Keyed do
        @moduledoc "hearth:owned"
      end
      """

      igniter =
        gen_keyed_and_petstore()
        |> Igniter.create_new_file("lib/test/integrations/keyed.ex", owned, on_exists: :overwrite)
        |> apply_igniter!()
        |> move_keyed()

      refute "lib/test/integrations/keyed.ex" in igniter.rms
      assert "lib/test/integrations/keyed/keyed_api.ex" in igniter.rms
      assert notice_text(igniter) =~ "lib/test/integrations/keyed.ex (hearth:owned)"
    end

    test "a later regen of the moved integration is a no-op" do
      gen_keyed_and_petstore()
      |> move_keyed()
      |> apply_igniter!()
      |> regen(["keyed"])
      |> assert_unchanged()
    end

    test "without it, the old module's files and config stay" do
      igniter = gen_keyed_and_petstore() |> move_keyed([])

      assert igniter.rms == []
      assert contents(igniter, @config_files) =~ ~r/Test\.Integrations\.Keyed,\s+api_key:/
    end

    test "halts without --module, or with the current module" do
      files = @petstore

      for argv <- [
            ["petstore", "--remove-old"],
            ["petstore", "--module", "Test.Integrations.Petstore", "--remove-old"]
          ] do
        igniter = test_project(files: files) |> regen(argv)
        assert has_issue?(igniter, ["--remove-old", "--module"])
      end
    end
  end

  describe "the .hearth.exs entry" do
    test "its module names Layer 1, keeping the domain gen chose" do
      files = %{
        @petstore
        | ".hearth.exs" => "[integrations: [petstore: [module: Test.Billing.Petstore]]]"
      }

      igniter =
        test_project(files: files)
        |> regen()

      assert_creates(igniter, "lib/test/billing/petstore.ex")

      assert created_file(igniter, "lib/test/billing/petstore.ex") =~
               "defmodule Test.Billing.Petstore do"
    end

    test "halts when it doesn't name a module" do
      files = %{@petstore | ".hearth.exs" => ~s|[integrations: [petstore: [source: "x.yaml"]]]|}

      igniter =
        test_project(files: files)
        |> regen()

      assert has_issue?(igniter, [".hearth.exs", "petstore", "module:"])
    end

    test "halts when its module isn't a module alias" do
      files = %{
        @petstore
        | ".hearth.exs" => ~s|[integrations: [petstore: [module: "Test.Integrations.Petstore"]]]|
      }

      igniter =
        test_project(files: files)
        |> regen()

      assert has_issue?(igniter, [".hearth.exs", ~s|"Test.Integrations.Petstore"|])
    end
  end

  describe "regen right after gen" do
    # Full spec prefix is `/v1`; the `Customers` subset alone shares
    # `/v1/customers`. regen must reuse gen's prefix, not recompute it
    # from the pruned subset — config/test.exs carries gen's base URL.
    @subset_prefix_spec JSON.encode!(%{
                          "openapi" => "3.0.0",
                          "info" => %{"title" => "Shop", "version" => "1.0"},
                          "servers" => [%{"url" => "https://api.example.com"}],
                          "paths" => %{
                            "/v1/customers/list" => %{
                              "get" => %{
                                "operationId" => "listCustomers",
                                "tags" => ["Customers"]
                              }
                            },
                            "/v1/customers/search" => %{
                              "get" => %{
                                "operationId" => "searchCustomers",
                                "tags" => ["Customers"]
                              }
                            },
                            "/v1/orders/list" => %{
                              "get" => %{"operationId" => "listOrders", "tags" => ["Orders"]}
                            }
                          }
                        })

    defp gen_then_regen(files, gen_args, name) do
      test_project(files: files)
      |> Igniter.compose_task("hearth.gen", gen_args)
      |> apply_igniter!()
      |> Igniter.compose_task("hearth.regen", [name])
    end

    test "is a no-op" do
      %{"priv/specs/petstore.yaml" => @petstore_3_0_yaml}
      |> gen_then_regen(
        ["priv/specs/petstore.yaml", "--integration", "Petstore"],
        "petstore"
      )
      |> assert_unchanged()
    end

    test "gen records the module, source and base path in .hearth.exs" do
      igniter =
        test_project(files: %{"priv/specs/shop.json" => @subset_prefix_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/shop.json",
          "--integration",
          "Shop",
          "--tag",
          "Customers"
        ])

      assert {:ok, [shop: entry]} =
               igniter |> created_file(".hearth.exs") |> Hearth.Config.parse()

      assert entry == [
               module: Test.Integrations.Shop,
               source: "priv/specs/shop.json",
               base_path: "/v1"
             ]

      refute created_file(igniter, "priv/hearth/shop.yaml") =~ "x-hearth"
    end

    test "halts when an edited pruned spec has a path outside the recorded base path" do
      pruned = """
      openapi: 3.0.0
      info: {title: Shop, version: "1.0"}
      paths:
        /v1/customers/list:
          get: {operationId: listCustomers}
        /v2/customers/list:
          get: {operationId: listCustomersV2}
      """

      igniter =
        test_project(
          files: %{
            "priv/hearth/shop.yaml" => pruned,
            ".hearth.exs" =>
              "[integrations: [shop: [module: Test.Integrations.Shop, base_path: \"/v1\"]]]"
          }
        )
        |> regen(["shop"])

      assert Enum.any?(igniter.issues, fn issue ->
               String.contains?(issue, "/v1") and String.contains?(issue, "/v2/customers/list")
             end)
    end

    test "is a no-op when the selected subset shares a longer path prefix" do
      %{"priv/specs/shop.json" => @subset_prefix_spec}
      |> gen_then_regen(
        ["priv/specs/shop.json", "--integration", "Shop", "--tag", "Customers"],
        "shop"
      )
      |> assert_unchanged()
    end
  end

  describe "ownership tokens" do
    test "a hearth:owned file is skipped, keeping its hand-edits" do
      igniter =
        test_project(files: Map.put(@petstore, @layer1, owned_layer1()))
        |> regen()

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
      refute created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "skipping #{@layer1} (hearth:owned)"
    end

    test "a file with no token is overwritten" do
      igniter =
        test_project(
          files: Map.put(@petstore, @layer1, "defmodule Test.Integrations.Petstore do\nend\n")
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end

    test "a hearth:collaborating file is regenerated when the prompt is accepted" do
      collaborating =
        "defmodule Test.Integrations.Petstore do\n  @moduledoc \"hearth:collaborating\"\nend\n"

      igniter =
        test_project(files: Map.put(@petstore, @layer1, collaborating))
        |> regen()

      # test mode auto-accepts the per-file prompt
      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end
  end

  describe "the external test scaffold" do
    test "is created when absent" do
      igniter =
        test_project(files: @petstore)
        |> regen()

      assert_creates(igniter, @external)
    end

    test "is never overwritten — even without an ownership token" do
      edited = "defmodule Test.Integrations.PetstoreExternalTest do\n  # user edited\nend\n"

      igniter =
        test_project(files: Map.put(@petstore, @external, edited))
        |> regen()

      assert created_file(igniter, @external) =~ "# user edited"
      assert notice_text(igniter) =~ "keeping #{@external}"
    end
  end
end
