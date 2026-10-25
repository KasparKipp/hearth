defmodule Mix.Tasks.Hearth.RegenTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @petstore_3_0_yaml File.read!("test/fixtures/specs/petstore-3.0.yaml")

  # A pruned spec as `gen` writes it: the spec plus an `x-hearth`
  # block naming the integration's Layer 1 module.
  @petstore_pruned @petstore_3_0_yaml <>
                     "\nx-hearth:\n  module: Test.Integrations.Petstore\n"

  @shop_pruned """
  openapi: 3.0.0
  info: {title: Shop, version: "1.0"}
  servers: [{url: "https://api.example.com"}]
  paths:
    /customers:
      get: {operationId: listCustomers}
  x-hearth: {base_path: "", source: priv/specs/shop.json, module: Test.Integrations.Shop}
  """

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
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
        |> regen()

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @layer2)
      assert_creates(igniter, @layer3)

      assert created_file(igniter, @layer1) =~ "defmodule Test.Integrations.Petstore do"
      assert created_file(igniter, @layer2) =~ "@callback list_pets("
    end

    test "halts when the pruned spec is missing" do
      igniter =
        test_project()
        |> regen()

      assert has_issue?(igniter, ["no pruned spec for Petstore", "priv/hearth/petstore.yaml"])
    end
  end

  describe "naming integrations" do
    test "halts with a helpful message when nothing is named and --all is absent" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
        |> regen([])

      assert has_issue?(igniter, ["--all", "mix hearth.regen stripe"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end

    test "the name is case-insensitive: Petstore reads priv/hearth/petstore.yaml" do
      test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
      |> regen(["Petstore"])
      |> assert_creates(@layer1)
    end

    test "a snake_case name maps to its snake_case pruned spec" do
      pruned =
        @petstore_3_0_yaml <> "\nx-hearth:\n  module: Test.Integrations.SendGrid\n"

      test_project(files: %{"priv/hearth/send_grid.yaml" => pruned})
      |> regen(["SendGrid"])
      |> assert_creates("lib/test/integrations/send_grid.ex")
    end

    test "comma-separated names regenerate each integration" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_pruned,
            "priv/hearth/shop.yaml" => @shop_pruned
          }
        )
        |> regen(["petstore, shop"])

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @shop_layer1)
      assert notice_text(igniter) =~ "Regenerated Test.Integrations.Petstore"
      assert notice_text(igniter) =~ "Regenerated Test.Integrations.Shop"
    end

    test "one missing integration halts the whole run" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
        |> regen(["petstore,stripe"])

      assert has_issue?(igniter, ["no pruned spec for Stripe"])
    end

    test "rejects a name that isn't a single alias segment" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
        |> regen(["Test.Integrations.Petstore"])

      assert has_issue?(igniter, ["\"Test.Integrations.Petstore\"", "integration name"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end

    test "--all regenerates every pruned spec under priv/hearth" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_pruned,
            "priv/hearth/shop.yaml" => @shop_pruned
          }
        )
        |> regen(["--all"])

      assert_creates(igniter, @layer1)
      assert_creates(igniter, @shop_layer1)
    end

    test "--all halts when there are no pruned specs" do
      igniter =
        test_project()
        |> regen(["--all"])

      assert has_issue?(igniter, ["no pruned specs", "priv/hearth/"])
    end

    test "--all together with names halts rather than guess" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
        |> regen(["petstore", "--all"])

      assert has_issue?(igniter, ["--all"])
      refute Rewrite.has_source?(igniter.rewrite, @layer1)
    end
  end

  describe "x-hearth.module" do
    test "names the Layer 1 module, keeping the domain gen chose" do
      pruned = @petstore_3_0_yaml <> "\nx-hearth:\n  module: Test.Billing.Petstore\n"

      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => pruned})
        |> regen()

      assert_creates(igniter, "lib/test/billing/petstore.ex")

      assert created_file(igniter, "lib/test/billing/petstore.ex") =~
               "defmodule Test.Billing.Petstore do"
    end

    test "halts when the pruned spec doesn't name its module" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_3_0_yaml})
        |> regen()

      assert has_issue?(igniter, ["priv/hearth/petstore.yaml", "x-hearth", "module:"])
    end

    test "halts when x-hearth.module isn't a module name" do
      pruned = @petstore_3_0_yaml <> "\nx-hearth:\n  module: test.integrations.petstore\n"

      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => pruned})
        |> regen()

      assert has_issue?(igniter, ["priv/hearth/petstore.yaml", "test.integrations.petstore"])
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

    test "gen records the base path and source in the pruned spec" do
      igniter =
        test_project(files: %{"priv/specs/shop.json" => @subset_prefix_spec})
        |> Igniter.compose_task("hearth.gen", [
          "priv/specs/shop.json",
          "--integration",
          "Shop",
          "--tag",
          "Customers"
        ])

      {:ok, pruned} =
        created_file(igniter, "priv/hearth/shop.yaml") |> YamlElixir.read_from_string()

      assert pruned["x-hearth"] == %{
               "base_path" => "/v1",
               "source" => "priv/specs/shop.json",
               "module" => "Test.Integrations.Shop"
             }
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
      x-hearth: {base_path: /v1, source: priv/specs/shop.json, module: Test.Integrations.Shop}
      """

      igniter =
        test_project(files: %{"priv/hearth/shop.yaml" => pruned})
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
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_pruned,
            @layer1 => owned_layer1()
          }
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def hand_written, do: :mine"
      refute created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "skipping #{@layer1} (hearth:owned)"
    end

    test "a file with no token is overwritten" do
      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_pruned,
            @layer1 => "defmodule Test.Integrations.Petstore do\nend\n"
          }
        )
        |> regen()

      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end

    test "a hearth:collaborating file is regenerated when the prompt is accepted" do
      collaborating =
        "defmodule Test.Integrations.Petstore do\n  @moduledoc \"hearth:collaborating\"\nend\n"

      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_pruned,
            @layer1 => collaborating
          }
        )
        |> regen()

      # test mode auto-accepts the per-file prompt
      assert created_file(igniter, @layer1) =~ "def new("
      assert notice_text(igniter) =~ "regenerating #{@layer1}"
    end
  end

  describe "the external test scaffold" do
    test "is created when absent" do
      igniter =
        test_project(files: %{"priv/hearth/petstore.yaml" => @petstore_pruned})
        |> regen()

      assert_creates(igniter, @external)
    end

    test "is never overwritten — even without an ownership token" do
      edited = "defmodule Test.Integrations.PetstoreExternalTest do\n  # user edited\nend\n"

      igniter =
        test_project(
          files: %{
            "priv/hearth/petstore.yaml" => @petstore_pruned,
            @external => edited
          }
        )
        |> regen()

      assert created_file(igniter, @external) =~ "# user edited"
      assert notice_text(igniter) =~ "keeping #{@external}"
    end
  end
end
